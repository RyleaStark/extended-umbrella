# Changelog

All notable changes to the Extended Umbrella package for Litecoin ElectrumX are documented here.

## 2.0.0-umbrel.6 — 2026-08-10

### Fixed

- Caps Litecoin Electrum protocol negotiation at 1.5 to match Litecoin Core 0.21.5.x RPC capabilities.
- Correctly disables peer announcements by passing an empty `PEER_ANNOUNCE` value.

### Changed

- Pins the immutable multi-architecture `v2.0.0-umbrel.5` daemon index.
- Uses a shell-free non-root runtime with exact Python dependency constraints and verified RocksDB create/read/write support.
- Updates source and support links to `RyleaStark/umbrel-litecoin-electrumx`.
- Preserves the existing index path, provider aliases, GUI, wallet port 51003, and private admin RPC 8000.

## 2.0.0-umbrel.4 — 2026-08-10

### Changed

- Republishes the daemon as `ghcr.io/ryleastark/umbrel-litecoin-electrumx`.
- Adds source, version, revision, and product-title OCI metadata to the multi-platform image.
- Keeps ElectrumX 2.0, index data, provider aliases, GUI, wallet port 51003, and private admin RPC 8000 unchanged.

## 2.0.0-umbrel.3 — 2026-08-10

### Fixed

- Restores the centered ElectrumX logo on Tor wallet QR codes to match Local connections and the shared Litecoin indexer UI convention.
- Keeps ElectrumX 2.0, existing index data, provider aliases, wallet port 51003, and private admin RPC port 8000 unchanged.

## 2.0.0-umbrel.2 — 2026-08-09

### Changed

- Replaces the legacy interface with the approved responsive Litecoin ElectrumX dashboard and atomic Litecoin identity.
- Adds accessible Local and Tor connection details with locally generated wallet QR codes.
- Keeps ElectrumX 2.0, existing index data, provider aliases, wallet port 51003, and private admin RPC port 8000 unchanged.
