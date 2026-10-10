# License guide

This project contains independently licensed components. The root MIT license applies to original project tooling and documentation only; it does not replace the licenses of component code, third-party dependencies, or game resources.

| Component | Applicable terms |
| --- | --- |
| Original project tools and documentation | MIT; see [LICENSE](LICENSE) |
| Xash RT engine | GPL-3.0-or-later for engine files carrying those notices; separately licensed bundled code retains its terms |
| Gameplay SDK | Valve Half-Life 1 SDK license; see the SDK repository's `LICENSE`. Distributions must be free and retain the required license and notices |
| RayTracedGL1 | MIT, with separately licensed third-party dependencies |
| Menu | GPL-2.0-or-later for menu files carrying those notices; dependencies retain their terms |
| Mod resources | Distributed separately through ModDB under their respective terms; not covered by this repository's MIT license |

Each source file's existing notice remains authoritative. Component `THIRD_PARTY_NOTICES.md` files identify bundled dependencies and their license locations. Keep these notices and the component license texts with redistributed binaries and source.

When distributing GPL-covered binaries, provide the corresponding source for that exact version, including the scripts needed to build it, under the applicable GPL terms. Tag coordinated source versions and retain their `sources.json` manifests. Keep Valve's SDK license and required warranty/liability notices with SDK distributions. The SDK's distribution restriction means that the combined project must not be advertised as uniformly MIT-licensed or uniformly under an OSI-approved license.

ModDB packaging is separate from GitHub publication. Resource attribution, redistribution permissions, and any third-party binary licenses must be checked for the actual release payload. Publishing code does not grant permission to relicense someone else's art, audio, or game data.
