# Changelog

All notable changes to the Extended Umbrella package for Litecoin Fulcrum are documented here.

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
