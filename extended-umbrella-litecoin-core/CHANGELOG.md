# Changelog

All notable changes to the Extended Umbrella package for Litecoin Core are documented here.

## 0.21.5.5-umbrel.3 — 2026-08-08

### Fixed

- Creates and repairs ownership and user-write permissions for the Litecoin and UI state directories before startup.
- Restores the complete Tor sidecar, hidden-service template, persistent RPC credential generation, and package data skeleton.
- Adds the Litecoin app icon and complete listener/environment wiring.

## 0.21.5.5-umbrel.1 — 2026-08-08

### Changed

- Publishes Litecoin Core under the third-party store ID `extended-umbrella-litecoin-core`.
- Routes the Umbrel auth proxy to the package's deterministic app container name.
