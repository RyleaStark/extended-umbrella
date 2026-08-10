# Changelog

All notable changes to the Extended Umbrella package for Litecoin Fulcrum are documented here.

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
