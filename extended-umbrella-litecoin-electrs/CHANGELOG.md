# Changelog

All notable changes to the Extended Umbrella package for Litecoin Electrs are documented here.

## 3.4.0-dev.3752866-umbrel.10 — 2026-08-10

### Fixed

- Keeps all six chain blocks fixed in place while a progressive pulse moves across them only during genuine indexing.
- Preserves provider-reported completed progress as solid blocks independently from the pulse.
- Keeps ready, connecting, waiting, and degraded states static and disables animation, transforms, and filters for reduced motion.
- Keeps progress-only telemetry, Warn-level logging, the `electrs-v3` index, provider contract, and wallet port 51001 unchanged.

## 3.4.0-dev.3752866-umbrel.9 — 2026-08-10

### Fixed

- Opts into the provider's narrow progress-only stderr channel so genuine `Tx/History indexing is up to height=N` markers reach the private dashboard telemetry receiver during initial indexing.
- Retains Warn-level logging, preventing unrelated informational records such as client addresses and request URIs from entering the telemetry route.
- Retains the bounded RFC3164 tag parser, non-blocking internal-only syslog route, stale-progress expiry, and listener-authoritative readiness behavior.
- Keeps the maintained daemon image, `data/electrs-v3` index, provider contract, and wallet port 51001 unchanged.

## 3.4.0-dev.3752866-umbrel.8 — 2026-08-10

### Fixed

- Makes Address, Port, and Connection string copy controls work on HTTP-only Umbrel origins.
- Presents Local and Tor wallet connections as suffix-free `host:port` values and identifies the transport separately as `SSL: None`.
- Animates the six status blocks only while Electrs is indexing, makes completed progress solid, and honors reduced-motion preferences.
- Shows real initial-index progress from Electrs while its Electrum listener is intentionally unavailable, without inferring readiness from stale or completed markers.
- Keeps the maintained daemon, `data/electrs-v3` index, provider contract, and wallet port 51001 unchanged.

## 3.4.0-dev.3752866-umbrel.7 — 2026-08-10

### Fixed

- Keeps dashboard assets on HTTP for HTTP-only Umbrel origins instead of upgrading them to unsupported HTTPS.
- Removes ineffective HTTP-origin COOP and origin-agent-cluster headers while preserving frame denial, no-referrer, and the restrictive local-only content security policy.
- Keeps the maintained daemon, private cookie-file boundary, `data/electrs-v3` index, provider contract, and wallet port 51001 unchanged.

## 3.4.0-dev.3752866-umbrel.6 — 2026-08-10

### Changed

- Moves the maintained daemon to `ghcr.io/ryleastark/umbrel-litecoin-electrs` and pins its new immutable multi-architecture index.
- Preserves the mode-0600 RPC cookie-file boundary and distinct `data/electrs-v3` state path from the previous hotfix.

## 3.4.0-dev.3752866-umbrel.5 — 2026-08-10

### Security

- Removes Litecoin Core RPC credentials from Electrs command arguments and startup configuration logs.
- Provisions a mode-0600 cookie file through the update-safe pre-start hook instead.

### Changed

- Uses `data/electrs-v3` for the incompatible mempool-electrs index and leaves legacy index bytes untouched for rollback.

## 3.4.0-dev.3752866-umbrel.4 — 2026-08-10

### Changed

- Replaces the stale 2023 `losh11/electrs-ltc` lineage with `rust-litecoin/electrs-ltc` pinned at commit `3752866675daf7a3825e6cb7db847944bc4b3db8`.
- Packages the untagged upstream snapshot honestly as `mempool-electrs 3.4.0-dev-3752866`.
- Uses remote Litecoin Core JSON-RPC import and light mode for the separate-container Umbrel runtime.
- Publishes the daemon as `ghcr.io/ryleastark/umbrel-litecoin-electrs-daemon`, avoiding the orphaned old-source GHCR package.
- Uses a shell-free, digest-pinned Distroless C/C++ runtime instead of general-purpose Debian.
- Updates `stderrlog` to 0.6 so the active `thread_local` dependency receives its security fix.
- Starts a fresh index because mempool-electrs indexes are incompatible with legacy electrs indexes.
- Preserves the Electrs provider contract, GUI, Local/Tor details, and wallet port 51001.

## 0.9.12-umbrel.5 — 2026-08-09

### Changed

- Replaces the legacy interface with the approved responsive Litecoin Electrs dashboard.
- Adds accessible Local and Tor connection details with locally generated, product-branded wallet QR codes.
- Keeps Electrs 0.9.12, existing index data, and wallet port 51001 unchanged.
