# They Hunger Redux

A ray-traced version of the Half-Life mod They Hunger, built on Sultim's Xash RT engine and RayTracedGL1.

This repository contains the build tools. The code lives in the [engine](https://github.com/dead-chrysalid/they-hunger-redux-engine), [gameplay SDK](https://github.com/dead-chrysalid/they-hunger-redux-sdk), [renderer](https://github.com/dead-chrysalid/they-hunger-redux-renderer), and [menu](https://github.com/dead-chrysalid/they-hunger-redux-menu) repositories.

## Build

Windows x64. Install the prerequisites in the [build guide](docs/BUILDING.md), then run:

```powershell
git clone https://github.com/dead-chrysalid/they-hunger-redux.git
cd they-hunger-redux
.\tools\StillHunger.cmd sources
.\tools\StillHunger.cmd build-code
```

Maps, models, textures, and sounds are distributed separately. **ModDB download: forthcoming.**

To assemble and run the build with an existing mod installation, see [Run](docs/BUILDING.md#run).

## Credits

They Hunger's original team, Valve, the Xash3D/FWGS contributors, Sultim Tsyrendashiev, and the They Hunger Redux contributors. See [credits](CREDITS.md) and [component licenses](LICENSES.md).
