# Build verification

On 12 October 2026, a fresh GitHub clone of this project downloaded all four public components and their pinned dependencies, then passed `tools/StillHunger.cmd build-code` on Windows x64.

- Complete engine, menu, renderer, and both gameplay DLLs built.
- Renderer: 7 tests passed.
- SDK: 7 tests passed.
- Engine synthetic physics tests passed.
- Client API 10 and renderer API 4 matched.
- Assembly tests passed, including resource preservation and rejection of stale builds or existing output.
- The assembled runtime passed a 25-second `they23` smoke test with a clean log.

SDL2 came from the official archive linked in the build guide. No previous build outputs or private mod resources were used. Playing the mod requires the separately distributed resources.
