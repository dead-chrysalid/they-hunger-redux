# Contributing

Start with the [build guide](docs/BUILDING.md) and the pinned revisions in `sources.json`. Please open project issues in the main repository and send code pull requests to the component they change.

For a bug report, include the mod version or component commits, Windows version, GPU/driver information when relevant, reproduction steps, and the relevant part of the log. Remove personal information before posting logs.

Keep changes focused and explain the behavior before and after. Run the affected component's tests. Changes across engine/client or engine/renderer boundaries must preserve client API 10 and renderer API 4, or explicitly coordinate a compatible change across all affected components.

Do not add mod maps, models, textures, audio, saves, compiled game binaries, or local build output to pull requests. Resources are distributed through ModDB. Code contributions must be compatible with the license of the component they modify; keep existing copyright and license notices.

The public `sources` and `build-code` commands support code-only contributions. Maintainers with the private content repository use the feature, build, smoke, finish, and preproduction workflow in [WORKFLOW.md](WORKFLOW.md) for playable releases. A successful source build does not establish that a gameplay change has passed a runtime smoke test.
