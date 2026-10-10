# Building on Windows

The coordinated target is **Windows x64, Release**, using Sultim's `ref_gl` and RayTracedGL1.

## Requirements

- Git for Windows, including its Bash and Unix helpers.
- Visual Studio 2022 or Build Tools 2022, with Desktop development with C++, the v143 toolchain, and a Windows SDK.
- CMake and CTest available in your shell.
- Python 3 for shader generation.
- Vulkan SDK, with `VULKAN_SDK` set and its shader compiler available.
- SDL2 development package **2.0.14** for Visual C++, extracted to the `project.json` SDL2 dependency path (`dependencies/SDL2_VC`). Obtain it from the [official SDL release archive](https://www.libsdl.org/release/SDL2-devel-2.0.14-VC.zip). The directory must contain `include/SDL.h` and `lib/x64/SDL2.dll`.

The build uses bundled FSR2 support. NVIDIA DLSS support is optional and requires the NVIDIA SDK if enabled; the documented command disables it to avoid requiring a separate proprietary SDK.

## Checkout and build

```powershell
git clone https://github.com/dead-chrysalid/they-hunger-redux.git
cd they-hunger-redux
.\tools\StillHunger.cmd sources
# Install the prerequisites and extract the SDL2 development package first.
.\tools\StillHunger.cmd build-code
```

`sources` clones the four public component repositories at the revisions recorded in `sources.json`. Existing repositories must be clean and at the recorded revision; the command refuses to reset your work. It initializes engine and renderer dependencies and uses the separately checked-out menu repository for the engine's menu submodule.

`build-code` builds the renderer and shaders, the complete engine/menu solution, and both SDK DLLs, then runs renderer and SDK tests. It writes build output inside the component repositories and logs under `.state/publication-build`. It does not need the private content repository, assemble a playable release, or deploy into production.

| Output | Location |
| --- | --- |
| Engine, launcher, filesystem, `ref_gl`, and menu | `repos/engine/x64/Release/` |
| RayTracedGL1 DLL and import library | `repos/rtgl1/Build/x64-Release/` |
| Compiled renderer shaders | `repos/rtgl1/Build/x64-Release/shaders/` |
| Client DLL | `repos/sdk/build/cl_dll/Release/client_amd64.dll` |
| Server DLL | `repos/sdk/build/dlls/Release/einar_amd64.dll` |

Use the matching ModDB release's resources for runtime testing. A valid playable engine installation needs its complete paired engine, menu, renderer, and SDL2 set; a valid SDK installation needs both game DLLs. Avoid mixing arbitrary component versions.

## Maintainer workflow

`project.json` remains the path and interface authority. The other unified commands described in `WORKFLOW.md` require the private content repository and local dependencies. Keep production staging and promotion in that workflow. Run unified commands through `tools/StillHunger.cmd` so the Windows environment bootstrap is applied.
