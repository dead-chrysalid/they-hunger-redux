# They Still Hunger development workflow

## What lives where

`project.json` is the path authority. The five repositories under `repos` are independent:

- `engine`: Xash engine and the `ref_gl` integration.
- `sdk`: client and game DLLs.
- `rtgl1`: RayTracedGL1 renderer, generated shaders, and editor tests.
- `mainui`: source for the engine’s pinned `menu.dll`.
- `content`: the runtime-shaped `rt` and `StillHunger` trees. Authored binary assets use Git LFS.

`dependencies` holds copied, hash-protected SDL2 and stock Valve data. It is never linked into a runtime. `work` contains disposable feature worktrees, `runtime\preprod` holds the tested release candidate, and immutable release payloads live under `releases`.

## The everyday loop

Run commands from this directory:

`StillHunger.cmd` applies an execution-policy bypass only to the child PowerShell process running the project tool. It does not change the machine or user execution policy.

```powershell
.\tools\StillHunger.cmd new -Name lighting-pass
.\tools\StillHunger.cmd status -Name lighting-pass
.\tools\StillHunger.cmd sync -Name lighting-pass
.\tools\StillHunger.cmd build -Name lighting-pass
.\tools\StillHunger.cmd launch-feature -Name lighting-pass
.\tools\StillHunger.cmd smoke-feature -Name lighting-pass -Screenshots
```

`new` creates matching `codex/<name>` branches and worktrees for engine, SDK, RayTracedGL1, and content. The content worktree is also the feature runtime, so live-editor changes to glTF and JSON are ordinary Git changes in `work\<name>\runtime`.

Commit intentional changes inside the affected worktrees. `status` reports branches, commits, dirty files, ahead/behind counts against each canonical `master`, interface compatibility, verification freshness, and whether the feature is ready to finish.

`sync` is safe to run whenever another feature has finished first. It requires clean feature and canonical worktrees, merges each newer component `master` into the matching feature branch, and is a no-op for components that are already current. Any changed component—or a newer canonical `mainui`—invalidates the old build and smoke records, so rebuild and retest the combined result. If Git reports a conflict, resolve or abort it in the named feature worktree and rerun `sync`.

`build` compiles into component build directories and assembles only the feature runtime. It never writes into preprod or production.

## Texture authoring and release conversion

Run this once on a development machine:

```powershell
.\tools\Setup-TextureTools.cmd
```

The setup tool downloads the pinned official Compressonator CLI portable archive when needed, verifies its archive and installed-file hashes, and creates an ignored Python virtual environment under `tools\.venv`. No Python packages are installed because `tools\CreateKTX2.py` uses only the standard library.

Author replacement textures in a feature runtime's `rt\mat_dev` tree and test them there in renderer developer mode. `finish` compiles every supported source image to the matching path under `rt\mat` before packaging. Development sources, `mat_junction`, the cache, and conversion tools are excluded from release payloads.

## Testing and launches

`launch-feature` and `launch-preprod` are interactive and leave the process running. Smoke commands start a bounded process, record its executable, arguments, PID, start time, map, log, exit result, and optional screenshot, then close only that exact process.

Codex may launch these runtimes when it materially helps verification. Say “do not launch or interfere with the game” in a task whenever you want exclusive control; that instruction remains in force for that task.

The tools refuse to replace a runtime that is currently in use. An unrelated Xash installation may keep running, but performance-sensitive testing should wait until competing GPU load is gone.

## Finishing or abandoning a feature

After all affected work is committed and the last build/smoke record matches the branch tips:

```powershell
.\tools\StillHunger.cmd finish -Name lighting-pass
```

`finish` refuses dirty or stale work, including any component still behind `master` or a smoke result older than the current build. It merges each non-empty feature branch into local `master` with `--no-ff`, removes completed worktrees/branches, builds from clean detached master worktrees, creates an immutable release, and stages that exact release in preprod.

For an abandoned experiment, preserve any useful commits or patches, then remove only the matching worktrees and branches with normal Git worktree/branch commands. Do not delete another feature’s tree or an uncommitted content edit.

## Releases, production, and rollback

Test preprod before promotion:

```powershell
.\tools\StillHunger.cmd launch-preprod
.\tools\StillHunger.cmd smoke-preprod -Screenshots
.\tools\StillHunger.cmd promote -Release 1
.\tools\StillHunger.cmd smoke-production -Screenshots
```

Promotion copies the immutable release to a sibling staging directory, verifies release-owned hashes, carries forward user-owned settings and saves, and swaps directories only while production is not running. The preceding production directory is retained and recorded.

Use this if production must be restored:

```powershell
.\tools\StillHunger.cmd rollback
```

Do not manually edit a release directory. A manifest mismatch is a failed release, not something to waive.

## Understanding failures

Each command prints one JSON result. Build and smoke logs are referenced by path. A failed command does not advance the release, preprod, or production state.

Release manifests record all packaged hashes and the orchestration, engine, SDK, RayTracedGL1, mainui, and content commits. Dependency manifests under `manifests\dependencies` protect the copied SDL2 and Valve trees.

If an operation is interrupted, run `status` first. Remove a stale `.state\operation.lock` only after confirming that no `StillHunger.ps1` process is active.

## Private remotes and legacy cleanup

The imported upstream remotes are named `upstream`; `origin` is deliberately free. Add a future private host as `origin` independently in each component and in this orchestration repository.

Migration bundles and legacy-only material are under `archives\migration-20260723`. Original repositories and installations are dated rollback sources. Delete them only after the new production release, rollback, and recovery bundles have been trusted for an agreed period.
