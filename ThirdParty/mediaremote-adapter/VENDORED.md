# mediaremote-adapter (vendored)

- Upstream: https://github.com/ungive/mediaremote-adapter (BSD 3-Clause, see LICENSE)
- Commit: 73f14ab (2026-09-04)
- Included: `src/adapter`, `src/private`, `src/utility`, `include`, `bin/mediaremote-adapter.pl` (test client omitted; only `src/test/NowPlayingTest.h`, which `adapter/test.m` includes)
- Built by the `MediaRemoteAdapter` framework target in `project.yml` (no CMake). Unmodified.

Why: macOS 15.4+ blocks third-party apps from reading "Now Playing" (MediaRemote).
`/usr/bin/perl` is Apple-entitled, so the script loads this framework inside perl and prints JSON.
CoNo uses it to send explicit play/pause to non-Music apps and (later) to read title/artist/position.
If Apple closes this path, CoNo falls back to the media key.
