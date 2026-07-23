# They Still Hunger unified project contract

- Read `project.json` before acting; it is the only path and interface authority.
- Start new engine, SDK, RayTracedGL1, or content work with `tools\StillHunger.ps1 new -Name <feature>`. Work only in its matching `work\<feature>` trees.
- StillHunger uses Sultim `ref_gl` and RayTracedGL1, never the separate `ref_vk` project.
- Keep engine and SDK client API 10 compatible. Keep engine and RayTracedGL1 renderer API 4 compatible.
- Build commands are build-only. Never configure component builds to deploy directly into production.
- A valid engine runtime contains the complete paired engine, renderer, menu, and SDL2 set; a valid SDK runtime contains both game DLLs.
- Stage releases in preprod and smoke-test the exact payload before promotion. Preserve declared user-owned files on subsequent promotions.
- Agents may launch feature, preprod, and production runtimes when verification helps. Inspect existing processes first, announce interactive launches, and terminate only the exact process the agent started.
- Finish completed work by merging it into each canonical local `master` and removing completed branches/worktrees. If work intentionally remains experimental, record that explicitly in `feature.json` and at handoff.
- Do not delete dated archives, rollback installations, or legacy repositories without explicit user approval.
