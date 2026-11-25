# Build A19Core Modular 1.2

The workflow `.github/workflows/a19-build.yml` runs on pushes to this branch or by manual dispatch. It reconstructs the pinned v0.6 source, checks the overlay and all patch SHA-256 hashes, builds the native helpers and managed core, checks required exported symbols, archives the iOS application, and uploads `A19Core-Modular-1.2-unsigned`.

The IPA is unsigned for SideStore. A successful workflow is necessary but does not establish runtime correctness on iPhone 17. Start with all experimental options off; compare one option at a time with automatic diagnostics enabled.

No games, keys, firmware or device pairing records are included in the patch set.
