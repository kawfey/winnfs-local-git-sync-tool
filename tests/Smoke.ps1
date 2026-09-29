<#
Smoke test: builds a throwaway "share", repo, and snapshot folder, then exercises pull, plan,
push, and the abort paths.

  pwsh -File tests\Smoke.ps1
      share is a plain folder under the local temp folder (tests logic, not SMB)

  pwsh -File tests\Smoke.ps1 -ShareRoot \\server\share\some\folder\you\own
      share is a new, uniquely named subfolder created under ShareRoot, so renames, share
      modes, and robocopy run over real SMB. Nothing outside that new subfolder is touched,
      and the subfolder is left in place for you to inspect and delete.
#>
#Requires -Version 7.2
param([string]$ShareRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stamp = 'syncshare-smoke-' + (Get-Date -Format yyyyMMdd-HHmmss) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
$root  = Join-Path ([IO.Path]::GetTempPath()) $stamp
if ($ShareRoot) {
    if (-not (Test-Path -LiteralPath $ShareRoot -PathType Container)) { throw "ShareRoot '$ShareRoot' does not exist or is not a folder" }
    $share = Join-Path $ShareRoot $stamp
    if (Test-Path -LiteralPath $share) { throw "'$share' already exists; refusing to reuse it" }
    Write-Host "share under test: $share"
} else {
    $share = Join-Path $root 'share'
}
$snap  = Join-Path $root 'snap'
$repo  = Join-Path $root 'repo'
$mod   = Join-Path $PSScriptRoot '..' 'SyncShare.psm1'
foreach ($d in $share, $snap, $repo, (Join-Path $share 'Reference')) { $null = New-Item -ItemType Directory -Force -Path $d }

# seed the fake share, including things the tool must ignore
'alpha v1'   | Set-Content -NoNewline (Join-Path $share 'alpha.txt')
$null = New-Item -ItemType Directory -Force -Path (Join-Path $share 'sub')
'beta v1'    | Set-Content -NoNewline (Join-Path $share 'sub' 'beta.txt')
'big ref'    | Set-Content -NoNewline (Join-Path $share 'Reference' 'ref.bin')
'ignore me'  | Set-Content -NoNewline (Join-Path $share 'Thumbs.db')

# repo with an initial commit on main
& git -C $repo init -q -b main
& git -C $repo commit -q --allow-empty -m 'init'

$cfgPath = Join-Path $root 'config.json'
@{
  SharePath = $share; SnapshotPath = $snap; RepoPath = $repo
  ExcludeDirs = @('Reference'); ExcludeFiles = @('Thumbs.db','~$*')
  LogPath = (Join-Path $root 'logs'); PlanPath = (Join-Path $root 'plans')
} | ConvertTo-Json | Set-Content $cfgPath

Import-Module $mod -Force
Initialize-SyncRepo -ConfigPath $cfgPath

function Step($name, [scriptblock]$body) { Write-Host "`n== $name"; & $body }

Step 'pull 1: share into main' {
    Invoke-SharePull -ConfigPath $cfgPath
    if (-not (Test-Path (Join-Path $repo 'alpha.txt')))          { throw 'alpha not merged' }
    if (Test-Path (Join-Path $repo 'Reference'))                 { throw 'excluded dir leaked into main' }
    if (Test-Path (Join-Path $repo 'Thumbs.db'))                 { throw 'excluded file leaked into main' }
    if (Test-Path (Join-Path $snap '.git'))                      { throw 'git metadata in snapshot' }
}

Step 'local edit, add, delete; plan; push' {
    'alpha v2' | Set-Content -NoNewline (Join-Path $repo 'alpha.txt')
    'gamma v1' | Set-Content -NoNewline (Join-Path $repo 'gamma.txt')
    Remove-Item (Join-Path $repo 'sub' 'beta.txt')
    & git -C $repo add -A; & git -C $repo commit -q -m 'edits'
    $plan = Get-SyncPlan -ConfigPath $cfgPath
    Invoke-SharePush -PlanPath $plan -ConfigPath $cfgPath -Confirm:$false
    if ((Get-Content (Join-Path $share 'alpha.txt') -Raw) -ne 'alpha v2') { throw 'alpha not pushed' }
    if (-not (Test-Path (Join-Path $share 'gamma.txt')))                    { throw 'gamma not added' }
    if (Test-Path (Join-Path $share 'sub' 'beta.txt'))                        { throw 'beta not removed' }
    $trashed = Get-ChildItem (Join-Path $share '_sync_trash') -Recurse -File
    if ($trashed.Count -ne 2) { throw "expected 2 trashed files (alpha v1, beta v1), got $($trashed.Count)" }
    if (Test-Path (Join-Path $share 'Reference' 'ref.bin') -PathType Leaf -ErrorAction Stop) { } else { throw 'reference file disturbed' }
}

Step 'coworker edits share after baseline: plan must refuse (exit 30)' {
    'alpha v3 by coworker' | Set-Content -NoNewline (Join-Path $share 'alpha.txt')
    'alpha v2b' | Set-Content -NoNewline (Join-Path $repo 'alpha.txt')
    & git -C $repo commit -q -am 'my edit'
    $failed = $false
    try { Get-SyncPlan -ConfigPath $cfgPath | Out-Null } catch { $failed = $_.Exception.Message -like '*exit 30*' }
    if (-not $failed) { throw 'plan did not refuse a moved share' }
}

Step 'pull 2: expect a conflict on alpha.txt (exit 20), resolve, complete' {
    $conflict = $false
    try { Invoke-SharePull -ConfigPath $cfgPath } catch { $conflict = $_.Exception.Message -like '*exit 20*' }
    if (-not $conflict) { throw 'expected merge conflict' }
    'alpha v4 merged' | Set-Content -NoNewline (Join-Path $repo 'alpha.txt')
    & git -C $repo add -A; & git -C $repo commit -q -m 'resolve'
    Complete-SharePull -ConfigPath $cfgPath
    $plan = Get-SyncPlan -ConfigPath $cfgPath
    Invoke-SharePush -PlanPath $plan -ConfigPath $cfgPath -Confirm:$false
    if ((Get-Content (Join-Path $share 'alpha.txt') -Raw) -ne 'alpha v4 merged') { throw 'resolution not pushed' }
}

Step 'held-open file aborts the push and restores state' {
    if (-not $IsWindows) { Write-Host '   skipped: share-mode locking is only enforced on Windows'; return }
    'alpha v5' | Set-Content -NoNewline (Join-Path $repo 'alpha.txt')
    & git -C $repo commit -q -am 'v5'
    $plan = Get-SyncPlan -ConfigPath $cfgPath
    $fs = [IO.File]::Open((Join-Path $share 'alpha.txt'), 'Open', 'Read', 'None')   # exclusive handle
    try {
        $msg = $null
        try { Invoke-SharePush -PlanPath $plan -ConfigPath $cfgPath -Confirm:$false } catch { $msg = $_.Exception.Message }
        if (-not $msg)                              { throw 'push succeeded against a held-open file' }
        if ($msg -notlike '*cannot rename*to trash*') { throw "push failed for the wrong reason: $msg" }
    } finally { $fs.Dispose() }
    if ((Get-Content (Join-Path $share 'alpha.txt') -Raw) -ne 'alpha v4 merged') { throw 'original was disturbed' }
    if (Get-ChildItem $share -Filter '*.~sync~*' -Recurse) { throw 'temp file left behind' }
    Invoke-SharePush -PlanPath (Get-SyncPlan -ConfigPath $cfgPath) -ConfigPath $cfgPath -Confirm:$false
    if ((Get-Content (Join-Path $share 'alpha.txt') -Raw) -ne 'alpha v5') { throw 'retry after unlock did not push' }
}

Step 'path rules' {
    foreach ($bad in 'CON.txt', 'a/../b', 'sub/name. ', 'Reference/x.bin', '_sync_trash/x', 'a/.gitattributes') {
        if (-not (Test-ManagedPath $bad)) { throw "accepted bad path '$bad'" }
    }
    if (Test-ManagedPath 'sub/ok name (1).docx') { throw 'rejected a good path' }
}

Write-Host "`nALL STEPS PASSED  (local: $root; share: $share)"
