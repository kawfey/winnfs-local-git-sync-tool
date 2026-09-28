#Requires -Version 7.2
<#
SyncShare.psm1  (increment 1, UNTESTED: run tests\Smoke.ps1 against a scratch folder first)

Model
  main                      your work (normal working tree in RepoPath)
  refs/heads/share          linear history of raw share snapshots, committed from SnapshotPath
                            with a private index; SnapshotPath contains NO git metadata
  refs/sync/share-baseline  the exact share commit main was last reconciled with
  <share>\_sync_trash\<run> every file the push renames away, never deleted by the push

Invariants
  I1  every `share` commit tree == managed share subtree minus Exclude* and _sync_trash
  I2  the push never overwrites or deletes a share file; it only renames (two-rename protocol)
  I3  baseline ref advances only after a fully successful pull-merge or push-verify
  I4  a blob hash is always `git hash-object --no-filters`; autocrlf and attributes are off
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.1.0'
$script:BaselineRef = 'refs/sync/share-baseline'
$script:Sep = [IO.Path]::DirectorySeparatorChar
$script:ShareBranch = 'share'

# --------------------------------------------------------------------------- config

function Get-SyncConfig {
    [CmdletBinding()] param([string]$ConfigPath)
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
    $c = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable
    foreach ($k in 'SharePath','SnapshotPath','RepoPath') {
        if (-not $c.ContainsKey($k)) { throw "config: '$k' is required" }
    }
    $defaults = @{
        TrashDirName        = '_sync_trash'
        ExcludeDirs         = @()        # names or relative paths, robocopy /XD and planner reject
        ExcludeFiles        = @()        # names or wildcards, robocopy /XF and planner reject
        MaxTrackedFileBytes = 25MB       # a non-excluded file above this aborts the pull
        MaxDeletes          = 10         # push thresholds
        MaxModifies         = 50
        MaxChangeFraction   = 0.25
        MinFilesForFraction = 20         # fraction limit applies only at or above this tree size
        LogPath             = (Join-Path $PSScriptRoot 'logs')
        PlanPath            = (Join-Path $PSScriptRoot 'plans')
    }
    foreach ($k in $defaults.Keys) { if (-not $c.ContainsKey($k)) { $c[$k] = $defaults[$k] } }
    foreach ($d in $c.LogPath, $c.PlanPath) { $null = New-Item -ItemType Directory -Force -Path $d }
    $c.ExcludeDirs = @($c.ExcludeDirs) + $c.TrashDirName
    return $c
}

# --------------------------------------------------------------------------- run ids

function New-RunSuffix {
    # millisecond timestamp plus random suffix: two runs in the same second must not share a trash folder
    '{0}-{1}' -f (Get-Date -Format yyyyMMdd-HHmmss-fff), ([guid]::NewGuid().ToString('N').Substring(0, 4))
}

# --------------------------------------------------------------------------- logging

function Write-SyncLog {
    param([string]$RunId, [string]$Level, [string]$Message)
    $line = '{0} {1} {2} {3}' -f (Get-Date -Format o), $RunId, $Level.ToUpper(), $Message
    Add-Content -LiteralPath (Join-Path $script:Cfg.LogPath "sync-$(Get-Date -Format yyyy-MM).log") -Value $line -Encoding utf8
    if ($Level -eq 'error') { Write-Error -ErrorAction Continue $line } else { Write-Verbose $line }
}

# --------------------------------------------------------------------------- git

function Invoke-Git {
    <#
      Runs git against RepoPath. -WorkTree/-IndexFile point git at the snapshot dir without
      any .git inside it. Output is captured as UTF-8; NUL bytes survive in the strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$WorkTree,
        [string]$IndexFile,
        [switch]$AllowFail
    )
    $PSNativeCommandUseErrorActionPreference = $false
    $prevEnc = [Console]::OutputEncoding
    $saved = @{}
    foreach ($n in 'GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        [Environment]::SetEnvironmentVariable('GIT_DIR', (Join-Path $script:Cfg.RepoPath '.git'))
        [Environment]::SetEnvironmentVariable('GIT_WORK_TREE', $(if ($WorkTree) { $WorkTree } else { $script:Cfg.RepoPath }))
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $(if ($IndexFile) { $IndexFile } else { $null }))
        $out = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
            throw "git $($GitArgs -join ' ') exited $LASTEXITCODE`n$($out -join "`n")"
        }
        return ,@($out)
    }
    finally {
        [Console]::OutputEncoding = $prevEnc
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

function Get-GitRef {
    param([Parameter(Mandatory)][string]$Ref)
    $o = Invoke-Git -GitArgs @('rev-parse','-q','--verify', "$Ref^{commit}") -AllowFail
    if ($LASTEXITCODE -eq 0) { return ($o -join '').Trim() } else { return $null }
}

function Get-BlobHash {
    param([Parameter(Mandatory)][string]$LiteralPath)
    ((Invoke-Git -GitArgs @('hash-object','--no-filters','--', $LiteralPath)) -join '').Trim()
}

function Assert-RepoSettings {
    foreach ($pair in @(@('core.autocrlf','false'), @('core.safecrlf','false'), @('core.longpaths','true'))) {
        $v = (Invoke-Git -GitArgs @('config','--get', $pair[0]) -AllowFail) -join ''
        if ($v.Trim() -ne $pair[1]) { throw "repo setting $($pair[0]) must be '$($pair[1])' (is '$($v.Trim())'). Run Initialize-SyncRepo." }
    }
}

function Initialize-SyncRepo {
    <# One-time: pins the byte-fidelity settings on the local repo. #>
    [CmdletBinding()] param([string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    foreach ($pair in @(@('core.autocrlf','false'), @('core.safecrlf','false'), @('core.longpaths','true'), @('core.ignorecase','true'))) {
        $null = Invoke-Git -GitArgs @('config','--local', $pair[0], $pair[1])
    }
    $null = New-Item -ItemType Directory -Force -Path $script:Cfg.SnapshotPath
    if (Test-Path -LiteralPath (Join-Path $script:Cfg.SnapshotPath '.git')) { throw 'SnapshotPath must not contain .git' }
}

# --------------------------------------------------------------------------- path rules

$script:ReservedName = '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
$script:InvalidChars = [IO.Path]::GetInvalidFileNameChars()

function Test-ManagedPath {
    <# Returns $null when the git-relative path is acceptable on the share, else a reason string. #>
    param([Parameter(Mandatory)][string]$RelPath)
    if ($RelPath -match '[\r\n]') { return 'contains newline' }
    $segs = $RelPath -split '/'
    foreach ($s in $segs) {
        if ($s -in '', '.', '..')                        { return "bad segment '$s'" }
        if ($s -ne $s.TrimEnd(' ','.'))                  { return "trailing space or dot in '$s'" }
        if ($s.IndexOfAny($script:InvalidChars) -ge 0)   { return "invalid character in '$s'" }
        if ($s -match $script:ReservedName)              { return "reserved device name '$s'" }
    }
    $first = $segs[0]
    if ($first -ieq $script:Cfg.TrashDirName)           { return 'inside trash' }
    foreach ($x in $script:Cfg.ExcludeDirs) {
        $xn = ($x -replace '\\','/').TrimEnd('/')
        if ($RelPath -ilike "$xn/*" -or ($segs -icontains $xn)) { return "under excluded dir '$x'" }
    }
    foreach ($x in $script:Cfg.ExcludeFiles) {
        if ($segs[-1] -ilike $x) { return "matches excluded file pattern '$x'" }
    }
    if ($segs -icontains '.git')            { return 'git metadata' }
    if ($segs -icontains '.gitattributes')  { return '.gitattributes would alter blobs' }
    return $null
}

# --------------------------------------------------------------------------- snapshot (pull side)

function Invoke-SnapshotCopy {
    <# robocopy /MIR share -> snapshot, then an /L pass that must report nothing to do. #>
    param([Parameter(Mandatory)][string]$RunId)
    $c = $script:Cfg
    $log = Join-Path $c.LogPath "robocopy-$RunId.log"
    $common = @('/MIR','/XJ','/COPY:DAT','/R:2','/W:2','/NP','/NDL','/BYTES','/NJH')
    if ($c.ExcludeDirs.Count)  { $common += '/XD'; $common += $c.ExcludeDirs }
    if ($c.ExcludeFiles.Count) { $common += '/XF'; $common += $c.ExcludeFiles }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & robocopy $c.SharePath $c.SnapshotPath @common "/LOG+:$log" | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -band 24) { throw "robocopy copy pass failed, exit $rc (see $log)" }   # 8 = failures, 16 = fatal
        & robocopy $c.SharePath $c.SnapshotPath @common '/L' '/NJS' | Out-Null
        $rcL = $LASTEXITCODE
        if ($rcL -eq 0) { Write-SyncLog $RunId info "snapshot quiescent after attempt $attempt"; return }
        Write-SyncLog $RunId warn "share changed during copy (exit $rcL), retrying"
        Start-Sleep -Seconds (5 * $attempt)
    }
    throw 'share did not become quiescent across 3 copy attempts (exit 10)'
}

function Assert-SnapshotSane {
    param([Parameter(Mandatory)][string]$RunId)
    $c = $script:Cfg
    $root = $c.SnapshotPath.TrimEnd('\','/')
    $items = Get-ChildItem -LiteralPath $root -Recurse -Force
    foreach ($i in $items) {
        $rel = $i.FullName.Substring($root.Length + 1).Replace([string]$script:Sep, '/')
        if ($i.PSIsContainer) {
            if ($i.Name -ieq '.git') { throw "embedded repository at '$rel' on the share (exit 11)" }
            continue
        }
        $why = Test-ManagedPath $rel
        if ($why) { throw "snapshot contains unmanageable path '$rel': $why (exit 11)" }
        if ($i.Length -gt $c.MaxTrackedFileBytes) { throw "'$rel' is $($i.Length) bytes, above MaxTrackedFileBytes; add an exclusion or raise the limit (exit 11)" }
        if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "'$rel' is a reparse point (exit 11)" }
    }
    Write-SyncLog $RunId info "snapshot sane: $($items.Count) objects"
}

function Write-ShareSnapshotCommit {
    <# Commits SnapshotPath onto refs/heads/share using a private index. Returns the commit id. #>
    param([Parameter(Mandatory)][string]$RunId, [string]$Message)
    $c = $script:Cfg
    $idx = Join-Path $c.RepoPath '.git' 'share.index'
    $null = Invoke-Git -GitArgs @('read-tree','--empty') -WorkTree $c.SnapshotPath -IndexFile $idx
    $null = Invoke-Git -GitArgs @('add','-A','-f','--','.') -WorkTree $c.SnapshotPath -IndexFile $idx
    $tree   = (Invoke-Git -GitArgs @('write-tree') -WorkTree $c.SnapshotPath -IndexFile $idx) -join ''
    $parent = Get-GitRef "refs/heads/$($script:ShareBranch)"
    $ctArgs = @('commit-tree', $tree.Trim(), '-m', $Message)
    if ($parent) {
        $parentTree = (Invoke-Git -GitArgs @('rev-parse', "$parent^{tree}")) -join ''
        if ($parentTree.Trim() -eq $tree.Trim()) { Write-SyncLog $RunId info 'share unchanged since last snapshot'; return $parent }
        $ctArgs += @('-p', $parent)
    }
    $commit = ((Invoke-Git -GitArgs $ctArgs) -join '').Trim()
    $null = Invoke-Git -GitArgs @('update-ref', "refs/heads/$($script:ShareBranch)", $commit)
    Write-SyncLog $RunId info "share snapshot commit $commit"
    return $commit
}

# --------------------------------------------------------------------------- pull

function Invoke-SharePull {
    <#
      Safe to schedule. Never writes to the share.
      exit 0 ok | 10 not quiescent | 11 snapshot rejected | 20 merge conflict (resolve, then Complete-SharePull)
    #>
    [CmdletBinding()] param([string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    $runId = 'pull-' + (New-RunSuffix)
    Assert-RepoSettings
    Invoke-SnapshotCopy -RunId $runId
    Assert-SnapshotSane -RunId $runId
    $shareCommit = Write-ShareSnapshotCommit -RunId $runId -Message "share snapshot $runId`n`nTool: $($script:ToolVersion)"

    $baseline = Get-GitRef $script:BaselineRef
    if ($baseline -eq $shareCommit) { Write-SyncLog $runId info 'already at baseline'; return }

    if ((Invoke-Git -GitArgs @('status','--porcelain')) -join '') { throw 'main working tree is not clean; commit or stash first' }
    if (((Invoke-Git -GitArgs @('symbolic-ref','--short','HEAD')) -join '').Trim() -ne 'main') { throw 'HEAD must be main' }

    $mergeArgs = @('merge','--no-ff','--no-edit','-m',"pull share $runId ($shareCommit)", $shareCommit)
    if (-not $baseline) { $mergeArgs += '--allow-unrelated-histories' }
    $null = Invoke-Git -GitArgs $mergeArgs -AllowFail
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog $runId warn "merge conflict; resolve with 'git mergetool' then run Complete-SharePull"
        Set-Content -LiteralPath (Join-Path $script:Cfg.PlanPath 'pending-pull.txt') -Value $shareCommit
        throw 'merge conflict (exit 20)'
    }
    $null = Invoke-Git -GitArgs @('update-ref', $script:BaselineRef, $shareCommit)
    Write-SyncLog $runId info "baseline advanced to $shareCommit"
}

function Complete-SharePull {
    <# After the user resolved a conflicted merge and committed it. #>
    [CmdletBinding()] param([string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    $pending = Join-Path $script:Cfg.PlanPath 'pending-pull.txt'
    if (-not (Test-Path -LiteralPath $pending)) { throw 'no pending pull' }
    $shareCommit = (Get-Content -LiteralPath $pending -Raw).Trim()
    if ((Invoke-Git -GitArgs @('status','--porcelain')) -join '') { throw 'working tree not clean; finish the merge commit first' }
    $null = Invoke-Git -GitArgs @('merge-base','--is-ancestor', $shareCommit, 'main')   # throws if not merged
    $null = Invoke-Git -GitArgs @('update-ref', $script:BaselineRef, $shareCommit)
    Remove-Item -LiteralPath $pending
}

# --------------------------------------------------------------------------- plan

function Get-SyncPlan {
    <#
      exit 0 plan written | 30 share moved since baseline (run pull) | 31 threshold | 32 invalid path
      Entries come from `git diff --raw --no-renames -z baseline main`, which carries old and new blob ids.
    #>
    [CmdletBinding()] param([string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    $runId = 'plan-' + (New-RunSuffix)
    Assert-RepoSettings
    $baseline = Get-GitRef $script:BaselineRef
    if (-not $baseline) { throw 'no baseline; run Invoke-SharePull first' }
    if ((Invoke-Git -GitArgs @('status','--porcelain')) -join '') { throw 'main working tree is not clean' }
    if (((Invoke-Git -GitArgs @('symbolic-ref','--short','HEAD')) -join '').Trim() -ne 'main') { throw 'HEAD must be main' }

    # compare-and-swap precondition: the share must still equal the baseline
    Invoke-SnapshotCopy -RunId $runId
    Assert-SnapshotSane -RunId $runId
    $current = Write-ShareSnapshotCommit -RunId $runId -Message "pre-push snapshot $runId"
    if ($current -ne $baseline) { throw "share changed since baseline ($baseline -> $current); run Invoke-SharePull (exit 30)" }

    $head = Get-GitRef 'main'
    $raw = (Invoke-Git -GitArgs @('diff','--raw','--no-abbrev','--no-renames','-z', $baseline, $head)) -join "`n"
    $fields = $raw.Split([char]0)
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i + 1 -lt $fields.Count; $i += 2) {
        $meta = $fields[$i]; $path = $fields[$i + 1]
        if (-not $meta) { continue }
        # ":<oldmode> <newmode> <oldsha> <newsha> <status>"
        $m = $meta.TrimStart(':') -split ' '
        $e = [pscustomobject]@{ OldMode=$m[0]; NewMode=$m[1]; OldBlob=$m[2]; NewBlob=$m[3]; Status=$m[4]; Path=$path }
        if ($e.Status -notin 'A','M','D')          { throw "unsupported diff status '$($e.Status)' for '$path' (exit 32)" }
        if ($e.NewMode -in '120000','160000' -or $e.OldMode -in '120000','160000') { throw "symlink or submodule at '$path' (exit 32)" }
        $why = Test-ManagedPath $path
        if ($why) { throw "'$path': $why (exit 32)" }
        $entries.Add($e)
    }
    $treeCount = ((Invoke-Git -GitArgs @('ls-tree','-r','--name-only', $baseline)) | Where-Object { $_ }).Count
    $del = @($entries | Where-Object Status -eq 'D').Count
    $mod = @($entries | Where-Object Status -eq 'M').Count
    if ($del -gt $script:Cfg.MaxDeletes)   { throw "plan deletes $del files, above MaxDeletes (exit 31)" }
    if ($mod -gt $script:Cfg.MaxModifies)  { throw "plan modifies $mod files, above MaxModifies (exit 31)" }
    if ($treeCount -ge $script:Cfg.MinFilesForFraction -and ($del + $mod) / $treeCount -gt $script:Cfg.MaxChangeFraction) {
        throw "plan modifies or deletes $($del + $mod) of $treeCount tracked files, above MaxChangeFraction (exit 31)"
    }

    $plan = [pscustomobject]@{
        RunId=$runId; Tool=$script:ToolVersion; Baseline=$baseline; Head=$head
        HeadTree=((Invoke-Git -GitArgs @('rev-parse',"$head^{tree}")) -join '').Trim()
        Created=(Get-Date -Format o); Entries=$entries
    }
    $json = $plan | ConvertTo-Json -Depth 5
    $planFile = Join-Path $script:Cfg.PlanPath "$runId.json"
    Set-Content -LiteralPath $planFile -Value $json -Encoding utf8 -NoNewline
    $hash = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$planFile.sha256" -Value $hash
    Write-SyncLog $runId info "plan $planFile A=$(@($entries | Where-Object Status -eq 'A').Count) M=$mod D=$del sha256=$hash"
    $entries | Format-Table Status, Path -AutoSize | Out-String | Write-Host
    return $planFile
}

# --------------------------------------------------------------------------- share I/O (push side)

function Get-OfficeOwnerFiles {
    param([string]$Dir, [string]$Leaf)
    $cands = @("~`$$Leaf")
    if ($Leaf.Length -gt 2) { $cands += "~`$" + $Leaf.Substring(2) }
    $cands | ForEach-Object { Join-Path $Dir $_ } | Where-Object { [IO.File]::Exists($_) }
}

function Move-ShareFile {
    <# Rename only. Same share, never across volumes, never over an existing file. #>
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($To))
    [IO.File]::Move($From, $To)     # no overwrite overload: fails if $To exists or $From is held open
}

function Invoke-ShareEntry {
    <#
      Two-rename protocol for one plan entry. Throws on any anomaly after restoring the original.
        A: temp write, hash, rename into place
        M: temp write, hash, rename orig to trash, hash trash == OldBlob, rename temp into place, hash dest
        D: rename orig to trash, hash trash == OldBlob
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$RunId)
    $c = $script:Cfg
    $rel   = $Entry.Path.Replace('/', $script:Sep)
    $dest  = Join-Path $c.SharePath $rel
    $dir   = [IO.Path]::GetDirectoryName($dest)
    $leaf  = [IO.Path]::GetFileName($dest)
    $trash = Join-Path $c.SharePath $c.TrashDirName $RunId $rel
    $local = Join-Path $c.RepoPath $rel
    $tmp   = $null

    $owners = Get-OfficeOwnerFiles -Dir $dir -Leaf $leaf
    if ($owners) { throw "'$rel' appears open in Office ($($owners -join ', '))" }

    if ($Entry.Status -in 'A','M') {
        if ($Entry.Status -eq 'A' -and [IO.File]::Exists($dest)) { throw "'$rel' already exists on share (plan says add)" }
        if ((Get-BlobHash $local) -ne $Entry.NewBlob) { throw "local '$rel' does not match plan blob; main moved?" }
        $null = [IO.Directory]::CreateDirectory($dir)
        $tmp = "$dest.~sync~$([guid]::NewGuid().ToString('N'))"
        [IO.File]::Copy($local, $tmp)
        if ((Get-BlobHash $tmp) -ne $Entry.NewBlob) { [IO.File]::Delete($tmp); throw "temp write of '$rel' failed hash check" }
    }

    if ($Entry.Status -in 'M','D') {
        try { Move-ShareFile -From $dest -To $trash }
        catch { if ($tmp) { [IO.File]::Delete($tmp) }; throw "cannot rename '$rel' to trash (held open, or vanished): $($_.Exception.Message)" }
        if ((Get-BlobHash $trash) -ne $Entry.OldBlob) {
            Move-ShareFile -From $trash -To $dest
            if ($tmp) { [IO.File]::Delete($tmp) }
            throw "'$rel' changed on the share after the pre-push snapshot; restored, aborting"
        }
    }

    if ($tmp) {
        try { Move-ShareFile -From $tmp -To $dest }
        catch {
            if ($Entry.Status -eq 'M') { Move-ShareFile -From $trash -To $dest }
            [IO.File]::Delete($tmp)
            throw "cannot rename temp into place for '$rel': $($_.Exception.Message)"
        }
        if ((Get-BlobHash $dest) -ne $Entry.NewBlob) { throw "post-rename hash mismatch on '$rel' (share is in an unexpected state; inspect manually)" }
    }
    Write-SyncLog $RunId info "$($Entry.Status) $rel ok"
}

# --------------------------------------------------------------------------- push

function Invoke-SharePush {
    <#
      Never scheduled. Requires a plan from Get-SyncPlan and re-verifies it.
      exit 0 ok | 40 aborted mid-run (share consistent; re-plan) | 41 post-push tree mismatch
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PlanPath, [string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    Assert-RepoSettings
    $hash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash
    if ((Get-Content -LiteralPath "$PlanPath.sha256" -Raw).Trim() -ne $hash) { throw 'plan file altered since Get-SyncPlan' }
    $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    $runId = 'push-' + (New-RunSuffix)

    if ((Get-GitRef $script:BaselineRef) -ne $plan.Baseline) { throw 'baseline moved since the plan was made; re-plan' }
    if ((Get-GitRef 'main') -ne $plan.Head)                  { throw 'main moved since the plan was made; re-plan' }
    if ((Invoke-Git -GitArgs @('status','--porcelain')) -join '') { throw 'main working tree is not clean' }

    $summary = "A=$(@($plan.Entries | Where-Object Status -eq 'A').Count) M=$(@($plan.Entries | Where-Object Status -eq 'M').Count) D=$(@($plan.Entries | Where-Object Status -eq 'D').Count) -> $($script:Cfg.SharePath)"
    if (-not $PSCmdlet.ShouldProcess($summary, 'Push plan to share')) { return }

    # tripwire: any change on the share outside the trash, temp files, and plan paths aborts the run.
    # The -Action block runs in its own scope, so state is shared through -MessageData.
    $shareRoot = $script:Cfg.SharePath.TrimEnd('\','/')
    $ignore = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $plan.Entries) {
        $p = Join-Path $shareRoot $e.Path.Replace('/', $script:Sep)
        $null = $ignore.Add($p)
        $d = [IO.Path]::GetDirectoryName($p)
        while ($d -and $d.Length -gt $shareRoot.Length) { $null = $ignore.Add($d); $d = [IO.Path]::GetDirectoryName($d) }
    }
    $trip = [hashtable]::Synchronized(@{
        Tripped = $null
        Trash   = (Join-Path $shareRoot $script:Cfg.TrashDirName)
        Ignore  = $ignore
    })
    $fsw = [IO.FileSystemWatcher]::new($shareRoot)
    $fsw.IncludeSubdirectories = $true
    $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
    $action = {
        $t = $Event.MessageData
        $a = $Event.SourceEventArgs
        $paths = @($a.FullPath)
        if ($a -is [IO.RenamedEventArgs]) { $paths += $a.OldFullPath }
        foreach ($fp in $paths) {
            if ($fp -like "$($t.Trash)*" -or $fp -like '*.~sync~*' -or $t.Ignore.Contains($fp)) { continue }
            if (-not $t.Tripped) { $t.Tripped = "$($a.ChangeType) $fp" }
        }
    }
    $handlers = foreach ($ev in 'Changed','Created','Deleted','Renamed') {
        Register-ObjectEvent -InputObject $fsw -EventName $ev -Action $action -MessageData $trip
    }
    $fsw.EnableRaisingEvents = $true
    # adds first, then modifies, then deletes: an abort mid-run never leaves content missing
    $order = @{ A = 0; M = 1; D = 2 }
    $entriesOrdered = @($plan.Entries | Sort-Object { $order[$_.Status] }, Path)
    $done = 0
    try {
        foreach ($e in $entriesOrdered) {
            Start-Sleep -Milliseconds 50   # let the watcher deliver pending events
            if ($trip.Tripped) { throw "tripwire: $($trip.Tripped) during push (exit 40)" }
            Invoke-ShareEntry -Entry $e -RunId $runId
            $done++
        }
    }
    catch {
        Write-SyncLog $runId error "aborted after $done of $($plan.Entries.Count) entries: $($_.Exception.Message)"
        throw
    }
    finally {
        $fsw.EnableRaisingEvents = $false
        foreach ($h in $handlers) { Unregister-Event -SourceIdentifier $h.Name -ErrorAction SilentlyContinue; Remove-Job -Id $h.Id -Force -ErrorAction SilentlyContinue }
        $fsw.Dispose()
    }
    if ($trip.Tripped) { throw "tripwire: $($trip.Tripped) during push (exit 40); share entries already applied are consistent, re-plan" }

    # verify: fresh snapshot tree must equal main's tree
    Invoke-SnapshotCopy -RunId $runId
    Assert-SnapshotSane -RunId $runId
    $post = Write-ShareSnapshotCommit -RunId $runId -Message "push $runId`n`nPlan: $PlanPath`nPlanSHA256: $hash`nBaseline: $($plan.Baseline)`nHead: $($plan.Head)`nTool: $($script:ToolVersion)"
    $postTree = ((Invoke-Git -GitArgs @('rev-parse',"$post^{tree}")) -join '').Trim()
    if ($postTree -ne $plan.HeadTree) { throw "post-push share tree $postTree != main tree $($plan.HeadTree); do not re-run blindly, inspect (exit 41)" }
    $null = Invoke-Git -GitArgs @('notes','--ref=sync','add','-f','-F', $PlanPath, $post)
    $null = Invoke-Git -GitArgs @('merge','--no-ff','--no-edit','-m',"record push $runId ($post)", $post)
    $null = Invoke-Git -GitArgs @('update-ref', $script:BaselineRef, $post)
    Write-SyncLog $runId info "push complete; baseline $post; trash at $(Join-Path $script:Cfg.TrashDirName $runId)"
}

function Clear-SyncTrash {
    <# The only code path that deletes anything on the share, and only inside _sync_trash. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([int]$OlderThanDays = 30, [string]$ConfigPath)
    $script:Cfg = Get-SyncConfig -ConfigPath $ConfigPath
    $trash = Join-Path $script:Cfg.SharePath $script:Cfg.TrashDirName
    Get-ChildItem -LiteralPath $trash -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$OlderThanDays) } |
        ForEach-Object { if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove trash run')) { Remove-Item -LiteralPath $_.FullName -Recurse -Force } }
}

Export-ModuleMember -Function Initialize-SyncRepo, Invoke-SharePull, Complete-SharePull, Get-SyncPlan, Invoke-SharePush, Clear-SyncTrash, Test-ManagedPath
