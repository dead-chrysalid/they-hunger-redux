# They Still Hunger unified project contract

- Read `project.json` before acting; it is the only path and interface authority.
- Start new engine, SDK, RayTracedGL1, or content work with `tools\StillHunger.cmd new -Name <feature>`. Work only in its matching `work\<feature>` trees.
- StillHunger uses Sultim `ref_gl` and RayTracedGL1, never the separate `ref_vk` project.
- Keep engine and SDK client API 10 compatible. Keep engine and RayTracedGL1 renderer API 4 compatible.
- Build commands are build-only. Never configure component builds to deploy directly into production.
- A valid engine runtime contains the complete paired engine, renderer, menu, and SDL2 set; a valid SDK runtime contains both game DLLs.
- Stage releases in preprod and smoke-test the exact payload before promotion. Preserve declared user-owned files on subsequent promotions.
- Agents may launch feature, preprod, and production runtimes when verification helps. Inspect existing processes first, announce interactive launches, and terminate only the exact process the agent started.
- Finish completed work by merging it into each canonical local `master` and removing completed branches/worktrees. If work intentionally remains experimental, record that explicitly in `feature.json` and at handoff.
- Do not delete dated archives, rollback installations, or legacy repositories without explicit user approval.

## Ray-traced content authoring

- Follow Sultim's [texture replacement guide](https://github.com/sultim-t/xash-rt/discussions/124). Author texture overrides in `rt/mat_dev`; keep exported originals in `rt/mat_src` as development references; run `rt/CreateKTX2.py` to compile finished overrides into `rt/mat` before release. Conversion requires Python 3 and GPUOpen Compressonator's `compressonatorcli.exe` on `PATH`. Release payloads contain the compiled KTX2 files, never `mat_dev`, `mat_src`, the conversion cache, or the Python tool.
- Follow Sultim's [custom-map guide](https://github.com/sultim-t/xash-rt/discussions/150). Keep exported scene objects under `rtgl1_main_root`, preserve the documented glTF Separate export settings, and publish only `scenes.json`, each scene's `.gltf`/`.bin`, and project-owned textures.
- `mat_junction` exists only to display inherited textures while editing in Blender. Never use its textures for new objects, and never include any `mat_junction` directory in a release.
- Map, light, scene, and texture edits are source changes. Create a feature before authoring them and make the changes inside that feature's `work\<feature>\runtime` content worktree.
