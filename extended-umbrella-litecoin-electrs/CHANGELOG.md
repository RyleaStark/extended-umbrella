# Changelog

All notable changes to the Extended Umbrella package for Litecoin Electrs are documented here.

## 3.4.0-dev.3752866-umbrel.4 — 2026-08-10

### Changed

- Replaces the stale 2023 `losh11/electrs-ltc` lineage with `rust-litecoin/electrs-ltc` pinned at commit `3752866675daf7a3825e6cb7db847944bc4b3db8`.
- Packages the untagged upstream snapshot honestly as `mempool-electrs 3.4.0-dev-3752866`.
- Uses remote Litecoin Core JSON-RPC import and light mode for the separate-container Umbrel runtime.
- Publishes the daemon as `ghcr.io/ryleastark/umbrel-litecoin-electrs-daemon`, avoiding the orphaned old-source GHCR package.
- Uses a shell-free, digest-pinned Distroless C/C++ runtime instead of general-purpose Debian.
- Updates `stderrlog` to 0.6 so the active `thread_local` dependency receives its security fix.
- Starts a fresh index because mempool-electrs indexes are incompatible with legacy electrs indexes; no existing installations require migration.
- Preserves the Electrs provider contract, GUI, Local/Tor details, and wallet port 51001.

## 0.9.12-umbrel.5 — 2026-08-09

### Changed

- Replaces the legacy interface with the approved responsive Litecoin Electrs dashboard.
- Adds accessible Local and Tor connection details with locally generated, product-branded wallet QR codes.
- Keeps Electrs 0.9.12, existing index data, and wallet port 51001 unchanged.
