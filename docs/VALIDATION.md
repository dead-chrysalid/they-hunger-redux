# Publication verification · 10 October 2026

The coordinated component revisions are recorded in [sources.json](../sources.json).

| Check | Result |
| --- | --- |
| Engine, renderer, menu, and filtered SDK reachable-history audits | Passed: no mod-resource paths, oversized Git blobs, or recognized credential/private-key signatures |
| Original SDK commit identities and topology | All 1,356 mapped commits retain authors, committers, dates, messages, and parent topology |
| Repeat publication export | Reproduces every current public revision and retains SDK public metadata ancestry |
| Fresh source-only Windows x64 build | Complete engine/menu/renderer set and both SDK DLLs built |
| Renderer tests | 7 passed |
| SDK tests | 7 passed |
| Synthetic engine physics tests | Passed without mod model files |
| Project contract and historical-resource audit regression | Passed |
| Private feature and exact preproduction runtime smoke | Passed on `they23` |
| Compatibility | Client API 10; renderer API 4 |

The source-only build used a fresh GitHub checkout of the main project and public engine, renderer, menu, and pinned dependencies. The filtered SDK revision was prepared locally while its upload was pending; after upload, its public head was fetched and verified. The sole subsequent SDK publication change removed unused workflow files; compiler inputs were unchanged. The content repository and mod resources were absent from this source checkout.

Inherited component CI workflows are disabled. These results document local verification, not a GitHub Actions build status. Pattern-based history audits cover the listed checks and are not a guarantee against every possible secret or licensing issue.
