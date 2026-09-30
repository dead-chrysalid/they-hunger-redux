# They Hunger Redux unified project contract

- Read `project.json` before acting; it is the only path and interface authority.
- On Codex desktop for Windows, run every unified project command through `tools\StillHunger.cmd`; never invoke `tools\StillHunger.ps1` directly. The `.cmd` entrypoint collapses Codex's duplicate `Path`/`PATH` variables to one process-local value and calls Windows PowerShell by absolute system path, bypassing any bundled `powershell.exe` shim. The unified script resolves the installation that owns `git.exe`; shell-backed Git commands run inside that installation's login Bash so Codex cannot replace their helper PATH.
- Do not mutate the user or machine `Path`/`PATH` to work around project commands. If `basename`, `sed`, or `git-sh-setup` is ever missing, treat it as a wrapper bootstrap defect and fix `Initialize-GitToolchainPath` in `tools\StillHunger.ps1`; do not improvise a session-specific PATH command.
- Start new engine, SDK, RayTracedGL1, or content work with `tools\StillHunger.cmd new -Name <feature>`. Work only in its matching `work\<feature>` trees.
- Use `tools\StillHunger.cmd sync -Name <feature>` after another feature reaches `master`. It merges each component master into the clean feature worktree and invalidates stale build/smoke evidence. `finish` refuses a feature that remains behind master.
- They Hunger Redux uses Sultim `ref_gl` and RayTracedGL1, never the separate `ref_vk` project.
- Keep engine and SDK client API 10 compatible. Keep engine and RayTracedGL1 renderer API 4 compatible.
- Build commands are build-only. Never configure component builds to deploy directly into production.
- A valid engine runtime contains the complete paired engine, renderer, menu, and SDL2 set; a valid SDK runtime contains both game DLLs.
- Stage releases in preprod and smoke-test the exact payload before promotion. Preserve declared user-owned files on subsequent promotions.
- Exception for numeric profile defaults: use `tools\StillHunger.cmd hotfix-defaults -Name <hotfix> -SettingsFile <json>`. Only `project.json`'s `hotfixPolicy.numericDefaults` settings qualify. This command owns a temporary content worktree, integrates the template change into master, archives the affected configs, and applies only the named settings to idle production. It skips builds, releases, and preprod; all other changes retain the full feature/release pathway. Do not patch immutable release payloads or existing feature runtimes.
- Agents may launch feature, preprod, and production runtimes when verification helps. Inspect existing processes first, announce interactive launches, and terminate only the exact process the agent started.
- Finish completed work by merging it into each canonical local `master` and removing completed branches/worktrees. If work intentionally remains experimental, record that explicitly in `feature.json` and at handoff.
- Do not delete dated archives, rollback installations, or legacy repositories without explicit user approval.

## Ray-traced content authoring

- Follow Sultim's [texture replacement guide](https://github.com/sultim-t/xash-rt/discussions/124). Author texture overrides in `rt/mat_dev`; keep exported originals in `rt/mat_src` as development references. Provision the pinned local converter with `tools\Setup-TextureTools.cmd`; it verifies GPUOpen Compressonator and creates the ignored `tools\.venv` Python environment. Clean releases automatically run `tools\CreateKTX2.py` to compile finished overrides into `rt/mat`. Release payloads contain the compiled KTX2 files, never `mat_dev`, `mat_src`, the conversion cache, Python environment, or conversion tool.
- Follow Sultim's [custom-map guide](https://github.com/sultim-t/xash-rt/discussions/150). Keep exported scene objects under `rtgl1_main_root`, preserve the documented glTF Separate export settings, and publish only `scenes.json`, each scene's `.gltf`/`.bin`, and project-owned textures.
- `mat_junction` exists only to display inherited textures while editing in Blender. Never use its textures for new objects, and never include any `mat_junction` directory in a release.
- Map, light, scene, and texture edits are source changes. Create a feature before authoring them and make the changes inside that feature's `work\<feature>\runtime` content worktree.
