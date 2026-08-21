# Changelog

All notable changes to the Extended Umbrella package for Litecoin Core are documented here.

## 0.21.5.6-umbrel.2 — 2026-08-21

### Changed

- Updates the Litecoin dashboard to immutable GUI image v0.3.2 with the approved Node 24 dependency alignment.
- Adds verified OCI source, revision, and version provenance while preserving the existing Litecoin Core version, runtime user, ports, and persistent data paths.

## 0.21.5.6-umbrel.1 — 2026-08-10

### Security

- Upgrades the packaged Litecoin node from Core v0.21.5.5 to v0.21.5.6, including upstream MWEB/P2P validation and consensus-security changes.
- Pins the verified multi-architecture v0.3.1 GUI/node image by immutable OCI index digest.

### Changed

- Moves the image runtime and build toolchain to Node 24.19 LTS and applies supported dependency security updates.

## 0.21.5.5-umbrel.3 — 2026-08-08

### Fixed

- Creates and repairs ownership and user-write permissions for the Litecoin and UI state directories before startup.
- Restores the complete Tor sidecar, hidden-service template, persistent RPC credential generation, and package data skeleton.
- Adds the Litecoin app icon and complete listener/environment wiring.

## 0.21.5.5-umbrel.1 — 2026-08-08

### Changed

- Publishes Litecoin Core under the third-party store ID `extended-umbrella-litecoin-core`.
- Routes the Umbrel auth proxy to the package's deterministic app container name.
