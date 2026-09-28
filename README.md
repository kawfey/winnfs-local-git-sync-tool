# winnfs-local-git-sync-tool

PowerShell 7 module that keeps a local Git repository in two-way sync with a subfolder of a Windows SMB file share that has no version history, no recycle bin, and other people writing to it.

Status: **increment 1, not yet validated on Windows.** Run `tests/Smoke.ps1` before pointing it at a real share.

## Problem

A plain two-tree comparison (Robocopy, Beyond Compare, `Get-ChildItem` diffing) cannot tell "I created this file" from "a coworker deleted this file", or "my edit is newer" from "their edit is newer". Every such tool falls back to asking a human. Automation needs a third tree: the state of the share at the last successful reconciliation (the baseline). With a baseline, each path resolves by a three-way rule:

| Local vs baseline | Share vs baseline | Result |
|---|---|---|
| changed | unchanged | push |
| unchanged | changed | pull |
| changed | changed | merge conflict, human resolves |

This tool stores the baseline in Git, so Git's three-way merge does the pull-side reconciliation and `git diff baseline..main` is the push-side change set.

## Model

```
RepoPath (normal git repo)
  main                        your work
  refs/heads/share            linear history of raw share snapshots
  refs/sync/share-baseline    the share commit main was last reconciled with
  refs/notes/sync             push plans attached to the share commits they produced

SnapshotPath (plain folder, no .git inside)
  byte-for-byte copy of the managed share subtree, committed to `share`
  through a private index file (.git/share.index)

SharePath (the SMB share subfolder)
  _sync_trash/<run-id>/...    every file the push replaced or removed
```

### Invariants

- **I1** Every `share` commit's tree equals the managed share subtree, minus the configured exclusions and `_sync_trash`.
- **I2** The push never overwrites or deletes a file on the share. It only renames: originals go to `_sync_trash`, new content arrives as a same-directory temp file renamed into place.
- **I3** The baseline ref advances only after a clean pull merge or a verified push.
- **I4** All hashes are `git hash-object --no-filters`; `core.autocrlf` and `core.safecrlf` are off and `.gitattributes` is rejected, so blob ids are hashes of raw bytes.

The snapshot folder deliberately has no `.git` in it. Git is pointed at it through `GIT_WORK_TREE` and `GIT_INDEX_FILE`, so `robocopy /MIR` can mirror into it with no risk of deleting repository metadata and no reliance on `/XD` protecting destination-only items.

## Requirements

- Windows, PowerShell 7.2 or later
- Git for Windows (developed against 2.54)
- Read access to the share for pull; write and rename access for push
- Share subtree of modest size (designed around hundreds of objects, working files up to roughly 10 MB)

## Setup

1. Clone this repo somewhere local, for example `C:\tools\winnfs-local-git-sync-tool`.
2. Copy `config.sample.json` to `config.json` in the same folder and edit it (see [Configuration](#configuration)). `config.json` is git-ignored.
3. Create the working repo if you do not have one, with at least one commit on `main`:
   ```powershell
   git init -b main C:\work\repo
   git -C C:\work\repo commit --allow-empty -m init
   ```
4. Import the module and pin the repo settings:
   ```powershell
   Import-Module C:\tools\winnfs-local-git-sync-tool\SyncShare.psm1
   Initialize-SyncRepo
   ```
5. Run the smoke test once (see [Testing](#testing)).
6. First pull. `main` and the share have no common history yet, so this merge uses `--allow-unrelated-histories`; any file present in both with different bytes conflicts once. Resolve, commit, then run `Complete-SharePull`.

## Configuration

`config.json`:

| Key | Required | Default | Meaning |
|---|---|---|---|
| `SharePath` | yes | | UNC path of the managed subfolder, e.g. `\\fileserver\share\Team\Subfolder` |
| `SnapshotPath` | yes | | Local folder for the raw snapshot. Must not contain `.git` |
| `RepoPath` | yes | | Local Git repository holding `main` |
| `TrashDirName` | no | `_sync_trash` | Trash folder name at the share root. Always excluded |
| `ExcludeDirs` | no | `[]` | Directory names or relative paths to leave unmanaged (reference material, large read-only files). Passed to `robocopy /XD`, and rejected by the push planner |
| `ExcludeFiles` | no | `[]` | File names or wildcards to leave unmanaged (`Thumbs.db`, `~$*`). Passed to `robocopy /XF`, and rejected by the push planner |
| `MaxTrackedFileBytes` | no | 25 MB | A non-excluded file above this aborts the pull. Catches large files landing outside an excluded folder |
| `MaxDeletes` | no | 10 | Push plan limit on deletions |
| `MaxModifies` | no | 50 | Push plan limit on modifications |
| `MaxChangeFraction` | no | 0.25 | Push plan limit on (deletes + modifies) / tracked files |
| `LogPath` | no | `./logs` | Rolling log and robocopy logs |
| `PlanPath` | no | `./plans` | Push plan JSON files and their SHA-256 sidecars |

Every command accepts `-ConfigPath` to use a config other than `./config.json`.

## Usage

### Pull (share into `main`)

```powershell
Invoke-SharePull
```

1. `robocopy /MIR /XJ` from the share into `SnapshotPath`.
2. Re-run the same Robocopy command with `/L`. It must report nothing to copy, proving the share did not change during the copy window. Up to 3 attempts.
3. Reject the snapshot if it contains `.git`, `.gitattributes`, reparse points, Windows-invalid or reserved names, or a file above `MaxTrackedFileBytes`.
4. Commit the snapshot to `refs/heads/share` (skipped when the tree is unchanged).
5. Merge that commit into `main`. On a clean merge, advance the baseline.

Pull never writes to the share and is safe to run on a schedule.

On a merge conflict (exit 20) the baseline is not advanced. Resolve in the normal way (`git mergetool`; Beyond Compare works as the merge tool for Office and PDF files), commit, then:

```powershell
Complete-SharePull
```

### Push (`main` onto the share)

Push is two commands so the plan can be reviewed before anything on the share changes. `main` must be clean and checked out.

```powershell
$plan = Get-SyncPlan          # prints the A/M/D table and returns the plan file path
Invoke-SharePush -PlanPath $plan
```

`Get-SyncPlan`:

1. Takes a fresh snapshot and commits it. If it differs from the baseline, a coworker changed the share since your last reconciliation: exit 30, run a pull first. This is the compare-and-swap precondition.
2. Runs `git diff --raw --no-renames -z baseline main`. Each entry carries the old and new blob ids.
3. Rejects type changes, symlinks, submodules, and any path that is excluded, inside the trash, reserved, or invalid on Windows (exit 32).
4. Applies the `Max*` thresholds (exit 31).
5. Writes `plans/<run-id>.json` and a `.sha256` sidecar.

`Invoke-SharePush`:

1. Verifies the plan hash, and that `main` and the baseline have not moved since planning.
2. Asks for confirmation (`-Confirm:$false` to skip).
3. Arms a `FileSystemWatcher` on the share. Any create, change, delete, or rename outside the trash, the temp files, and the plan's own paths aborts the run.
4. Applies entries in the order adds, modifies, deletes, each with the two-rename protocol below.
5. Takes a fresh snapshot and requires its tree to equal `main`'s tree (exit 41 otherwise).
6. Attaches the plan as a Git note on the new share commit, merges it into `main` (identical trees, so the merge records the reconciliation point only), and advances the baseline.

### Two-rename protocol (per file)

For a modify of path `P` with baseline blob `B` and new blob `N`:

1. Abort if an Office owner file (`~$...`) for `P` exists.
2. Copy the local file to `P.~sync~<guid>` in the same directory; its hash must equal `N`.
3. Rename `P` to `_sync_trash/<run-id>/P`. Windows share modes are enforced by the server, so this fails if another client has `P` open without delete sharing (Word, Excel).
4. Hash the trashed copy; it must equal `B`. A mismatch means someone edited `P` after the plan snapshot: rename it back and abort.
5. Rename the temp file to `P`; its hash must equal `N`.

An add is steps 1, 2, and 5, with a precondition that `P` does not exist. A delete is steps 1, 3, and 4. `[IO.File]::Move` without the overwrite argument is used for every rename, so a rename never replaces an existing file.

Because the plan is always recomputed from `baseline..main` against a fresh snapshot, an aborted push is resumable: re-plan, and entries already applied drop out once a pull reconciles them.

### Trash cleanup

```powershell
Clear-SyncTrash -OlderThanDays 30
```

This is the only command that deletes anything on the share, and it only removes `_sync_trash/<run-id>` folders older than the threshold. It requires confirmation.

## Exit and error codes

Errors are thrown with the code in the message text.

| Code | Command | Meaning | Action |
|---|---|---|---|
| 10 | pull, plan, push | Share not quiescent across 3 copy attempts | Retry later |
| 11 | pull, plan, push | Snapshot rejected (bad path, embedded repo, oversize file, reparse point) | Fix on share or add an exclusion |
| 20 | pull | Merge conflict | Resolve, commit, `Complete-SharePull` |
| 30 | plan | Share changed since baseline | `Invoke-SharePull`, then re-plan |
| 31 | plan | Threshold exceeded | Review; raise the limit in config if intended |
| 32 | plan | Unsupported diff entry or invalid path | Fix in `main` |
| 40 | push | Aborted mid-run (lock, concurrent edit, tripwire) | Share is consistent per file; pull, then re-plan |
| 41 | push | Post-push tree does not match `main` | Inspect manually before running anything else |

## Recovery

- A file the push replaced or removed: `\\share\...\_sync_trash\<run-id>\<path>`.
- Any previous state of the share: `git log share`, then `git show <commit>:<path> > file` or `git restore --source=<commit> -- <path>` in a scratch worktree.
- Which plan produced a share commit: `git notes --ref=sync show <commit>`.
- Plans, hashes, and per-file results: `logs/sync-YYYY-MM.log`.

The local repository is the durable history. Back it up off the machine, for example with a scheduled `git bundle create <path>\repo.bundle --all`.

## Testing

```powershell
pwsh -File tests\Smoke.ps1
```

Builds a throwaway share, repo, and snapshot under `$env:TEMP` and exercises pull, push, the compare-and-swap refusal, a conflicted pull and its resolution, a held-open file aborting a push with the original intact, and the path rules. It never touches a real share.

The default run uses a plain local folder as the "share", which tests the logic but not SMB share-mode enforcement. For that, share the same folder over loopback (`net share smoke=<path> /grant:%USERNAME%,FULL` as administrator) and point `$share` in the script at `\\localhost\smoke`.

## Limitations

- Empty directories are not tracked. The push creates parent directories as needed and never removes directories.
- Renames are pushed as a delete plus an add.
- The Office owner-file check covers the common `~$` naming forms only; the rename in step 3 is the authoritative lock test.
- `FileSystemWatcher` over SMB can drop events under buffer overflow. It supplements the per-file hash checks; it does not replace them.
- Snapshot consistency relies on the `/L` retest, not a server-side snapshot. A write that starts and finishes entirely between the copy pass and the retest of a different file is not detected.

## Module layout

```
SyncShare.psm1         the module
config.sample.json     configuration template
tests/Smoke.ps1        end-to-end test against a temporary folder
```
