# Source publication

GitHub hosts the project tools and the engine, SDK, RayTracedGL1, and menu sources. The content repository and mod resources remain local and are distributed through ModDB.

## History

The component repositories preserve upstream and mod development history. Their upstream URLs are recorded in `sources.json`; local development repositories retain `upstream` remotes.

Engine, renderer, and menu repositories retain their GitHub fork relationship. Their public default branch is `master`, which contains the integrated Redux code. Inherited upstream Actions workflows are disabled for this publication rather than being presented as verified Redux CI.

The public SDK is a resource-filtered publication copy. Game-resource directories (`models`, `sound`, `sprites`, Android packaged assets and launcher art) are removed throughout the reachable published history. Empty commits and merge topology are retained so development context is not discarded. Rewritten commits retain their author, committer, dates, and messages. Their hashes change because their trees or ancestors changed. The private SDK repository is not rewritten.

`sources.json` records both the development revision and the corresponding public revision for every component. The publisher retains the full SDK commit mapping locally under the ignored publication workspace. The public SDK is an independent repository rather than a GitHub fork containing the upstream resource-bearing branch network.

Upstream engine launcher icons and upstream renderer documentation illustrations are source-project presentation files, rather than the mod's resource collection. Bundled development libraries and shader-generation code are retained because they are needed to build the renderer.

## Coordinated updates

1. Complete and integrate a feature using the local maintainer workflow.
2. Audit the source changes and their licenses; exclude content, temporary files, credentials, and build output.
3. Update the filtered SDK publication copy from its private source, retaining the mapping.
4. Push modified dependencies first, then the menu and remaining components. Publish only intended integration branches, not all local feature branches or internal Git refs.
5. Update public revisions in `sources.json` and verify a clean checkout and source build.
6. Tag the coordinated source version and link that source from the matching ModDB release.

Resources are never added to a GitHub release or uploaded as Git LFS objects. Avoid mirror pushes: they can publish private branches, backup refs, and unfiltered history.

The maintainer helper `tools/Export-PublicSources.py --development-root <private-project-root>` creates fresh publication copies and updates `sources.json`. Install `git-filter-repo==2.47.0` in an isolated Python environment before running it. It refuses to overwrite an existing export directory or export dirty component checkouts. Filtering is restricted to an independent SDK clone and preserves commit messages and encoding, including any textual references to old commit IDs. `tools/Audit-PublicSources.py` checks the complete reachable history for game-resource paths, oversized blobs, and common credential/private-key signatures. Review its findings before any push; automated pattern checks do not replace a manual source review.
