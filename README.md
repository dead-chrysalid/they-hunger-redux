<div align="center">

# They Hunger Redux

**A ray-traced return to They Hunger.**

[![Platform](https://img.shields.io/badge/platform-Windows_x64-30363d)](docs/BUILDING.md)
[![Renderer](https://img.shields.io/badge/renderer-RayTracedGL1-8f302d)](https://github.com/dead-chrysalid/they-hunger-redux-renderer)
[![Source](https://img.shields.io/badge/source-component_licenses-30363d)](LICENSES.md)

[Build from source](docs/BUILDING.md) · [Project components](#source-repositories) · [Credits](CREDITS.md) · [Contribute](CONTRIBUTING.md)

</div>

They Hunger Redux brings the They Hunger campaign to a customized Sultim Xash RT engine, with RayTracedGL1 rendering and a dedicated gameplay SDK and menu. This repository is the entry point for the source code and the tools that build the components together.

The project combines work from the original They Hunger creators, Valve, the Xash3D/FWGS community, Sultim Tsyrendashiev, and this mod's contributors. Each component preserves its development history and original licensing.

## Play

**ModDB release: forthcoming.** The download link will be added here when the mod page is published.

The playable mod and its resource files will be distributed through ModDB. Maps, models, textures, sounds, and the private content repository are not published on GitHub. A source checkout does not include a playable installation.

## Source repositories

| Component | Repository | Role |
| --- | --- | --- |
| Project | **they-hunger-redux** | Setup, source revisions, build tools, and project documentation |
| Engine | [they-hunger-redux-engine](https://github.com/dead-chrysalid/they-hunger-redux-engine) | Xash RT engine, `ref_gl` integration, and engine systems |
| Gameplay | [they-hunger-redux-sdk](https://github.com/dead-chrysalid/they-hunger-redux-sdk) | They Hunger client/server code, gameplay, and HUD |
| Renderer | [they-hunger-redux-renderer](https://github.com/dead-chrysalid/they-hunger-redux-renderer) | RayTracedGL1, shaders, and renderer/editor code |
| Menu | [they-hunger-redux-menu](https://github.com/dead-chrysalid/they-hunger-redux-menu) | Menu and mod settings |

[sources.json](sources.json) records the exact public revisions that belong together. The engine and SDK use client API **10**; the engine and renderer use renderer API **4**.

## Get the code

On Windows, with Git for Windows installed:

```powershell
git clone https://github.com/dead-chrysalid/they-hunger-redux.git
cd they-hunger-redux
.\tools\StillHunger.cmd sources
```

The setup command checks out the pinned source revisions and initializes their dependencies. See [Building](docs/BUILDING.md) for compiler requirements and the source-only build command.

## Licensing and history

The project tools use MIT. The engine, gameplay SDK, renderer, menu, and third-party dependencies retain their own terms; see [License guide](LICENSES.md). In particular, the gameplay SDK retains Valve's Half-Life SDK license and its free-distribution restriction.

The SDK publication history omits game resources throughout its history. Commit authors, messages, and development topology are retained, but affected commit IDs differ from the private development repository. See [Publication](docs/PUBLICATION.md) for the policy and revision mapping.
