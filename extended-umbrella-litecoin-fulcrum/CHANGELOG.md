# Changelog

All notable changes to the Extended Umbrella package for Litecoin Fulcrum are documented here.

## 2.1.2-umbrel.1 — 2026-08-21

- Updates the Fulcrum daemon from `2.1.1` to the immutable multi-architecture `2.1.2` release.
- Includes upstream internal correctness fixes, refactoring, and dependency refreshes.
- Retains GUI `v1.0.12`, existing ports, provider aliases, persistent data, and configuration; no migration is required.

## 2.1.1-umbrel.16 — 2026-08-21

- Updates the dashboard runtime to Fastify `5.12.1`, resolving CVE-2026-18504 and CVE-2026-16732.
- Keeps the decorative Connect-dialog border fixed at the outer modal edge while mobile content scrolls.
- Pins the immutable multi-architecture GUI release `v1.0.12`.

## 2.1.1-umbrel.15 — 2026-08-10

- Validates Litecoin Core txindex as a separate prerequisite instead of presenting it as Fulcrum indexing progress.
- Uses Fulcrum-owned stats or fresh complete UTC log records only for incomplete provider progress; logs never establish readiness.
- Rejects stale, future, malformed, partial, equal-to-Core, and ahead-of-Core fallback markers.
- Pins Fulcrum log timestamps to UTC and the immutable multi-architecture GUI release `v1.0.10`.

## 2.1.1-umbrel.14 — 2026-08-10

- Smooth the six-block indexing handoff into the completed state without moving block positions.
- Keep connecting, waiting, degraded, ready, and reduced-motion states static and provider-authoritative.

## 2.1.1-umbrel.13 — 2026-08-10

### Fixed

- Keeps all six chain blocks fixed in place while a progressive pulse moves across them only during genuine indexing.
- Preserves provider-reported completed progress as solid blocks independently from the pulse.
- Keeps ready, connecting, waiting, and degraded states static and disables animation, transforms, and filters for reduced motion.
- Keeps UI port 12109, Fulcrum 2.1.1, persistent index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.12 — 2026-08-10

### Fixed

- Keeps all six status blocks visibly animated whenever Fulcrum reports genuine indexing, including progress below the first completed block threshold.
- Keeps synchronized blocks solid and static, leaves non-indexing states still, and honors reduced-motion preferences.
- Keeps UI port 12109, Fulcrum 2.1.1, persistent index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.11 — 2026-08-10

### Fixed

- Makes Address, Port, and Connection string copy controls work on HTTP-only Umbrel origins.
- Presents Local and Tor wallet connections as suffix-free `host:port` values and identifies the transport separately as `SSL: None`.
- Animates real initial-indexing progress from Fulcrum's mounted log while its listener is not yet available, makes completed progress solid, and honors reduced-motion preferences.
- Rejects stale completed log heights as readiness evidence, so a closed listener cannot falsely report synchronization.
- Keeps UI port 12109, Fulcrum 2.1.1, persistent index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.10 — 2026-08-10

### Fixed

- Moves the Litecoin Fulcrum dashboard from port 2109 to 12109 so it can coexist with the official Bitcoin Fulcrum app.
- Keeps the public Litecoin wallet listener on port 51002 and leaves the daemon image, GUI image, persistent index, and provider aliases unchanged.

## 2.1.1-umbrel.9 — 2026-08-10

### Fixed

- Keeps dashboard assets on HTTP for HTTP-only Umbrel origins instead of upgrading them to unsupported HTTPS.
- Removes ineffective HTTP-origin COOP and origin-agent-cluster headers while preserving frame denial, no-referrer, and the restrictive local-only content security policy.
- Keeps Fulcrum 2.1.1, persistent index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.8 — 2026-08-10

### Fixed

- Restores the centered Fulcrum logo on Tor wallet QR codes to match Local connections and the shared Litecoin indexer UI convention.
- Keeps Fulcrum 2.1.1, existing index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.7 — 2026-08-09

### Changed

- Replaces the legacy interface with the approved responsive Litecoin Fulcrum dashboard.
- Adds accessible local and Tor connection details with locally generated wallet QR codes.
- Keeps Fulcrum 2.1.1, existing index data, provider aliases, and wallet port 51002 unchanged.

## 2.1.1-umbrel.3 — 2026-08-08

### Fixed

- Creates and repairs ownership and user-write permissions for Fulcrum database and log directories before startup.
- Restores the Tor sidecar, hidden-service template and export, persistent log capture, and package data skeleton.
- Adds the Fulcrum LTC app icon.

## 2.1.1-umbrel.1 — 2026-08-08

### Changed

- Publishes Litecoin Fulcrum under the third-party store ID `extended-umbrella-litecoin-fulcrum`.
- Routes the Umbrel auth proxy to the package's deterministic app container name.
