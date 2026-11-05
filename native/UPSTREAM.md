# Native source provenance

The native engine, integration helpers, shaders and content were extracted from
Stink-O's Orbital Laser v0.5.9 release asset:

https://github.com/Stink-O/orbital-laser/releases/download/v0.5.9/orbital.hnmod

SHA-256 (checked against the author's release SHA256SUMS):
`3cfd63b72e673c4275ff5ba5018662baf3ce01ddfbd8a4d98bdf1fbfe813f684`

Copyright (c) 2026 Stink-O. MIT license: see ../LICENSE; additional credits: ../NOTICE.
This is a maintained derivative, not an official upstream release.

The original native release pinned Horizon c06a83b1caa17ba7c9a7868f02645148436b2a6e.
This update targets Nightly 66f3981f522b24c250b21523a70080965b940424.
The native test SDK imports are explicit to avoid resolving their own fake modules
through the crate-level SDK alias when building tests.
The Planet Killer test indexes the latest forceload command times once, instead of
repeatedly scanning and allocating over the entire command list. Its terrain and
chunk-release assertions are retained; this does not change gameplay.
