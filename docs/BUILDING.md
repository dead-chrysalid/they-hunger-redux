# Build on Windows

## Requirements

- Git for Windows.
- Visual Studio 2022 or Build Tools 2022 with Desktop development with C++, v143, and a Windows SDK.
- CMake, CTest, and Python 3 available in your shell.
- Vulkan SDK, with `VULKAN_SDK` set.
- [SDL2 2.0.14 development package for Visual C++](https://www.libsdl.org/release/SDL2-devel-2.0.14-VC.zip). Extract its contents into `dependencies/SDL2_VC`, so that `include/SDL.h` and `lib/x64/SDL2.dll` exist there.

## Build

```powershell
git clone https://github.com/dead-chrysalid/they-hunger-redux.git
cd they-hunger-redux
.\tools\StillHunger.cmd sources
# Extract SDL2 into dependencies/SDL2_VC before building.
.\tools\StillHunger.cmd build-code
```

`sources` downloads the matching component revisions and dependencies. `build-code` builds Windows x64 Release binaries, compiles shaders, and runs tests. DLSS is disabled; FSR2 is included.

| Output | Directory |
| --- | --- |
| Launcher, engine, filesystem, renderer bridge, menu | `repos/engine/x64/Release/` |
| RayTracedGL1 DLL and library | `repos/rtgl1/Build/x64-Release/` |
| Renderer shaders | `repos/rtgl1/Build/x64-Release/shaders/` |
| Client DLL | `repos/sdk/build/cl_dll/Release/` |
| Server DLL | `repos/sdk/build/dlls/Release/` |

Build logs are in `.state/publication-build`. To play, use the matching ModDB release's resources; they are not included in the source repositories.

## Run

Assemble the build with an extracted mod release or existing installation:

```powershell
.\tools\StillHunger.cmd assemble -Resources "D:\Games\They Hunger Redux"
.\work\play\StartGame.cmd
```

This creates `work/play` with the resources, matching binaries, and compiled shaders. The resource installation stays untouched. Use `-Output work/play-2` to create another copy; existing output folders are never overwritten.
