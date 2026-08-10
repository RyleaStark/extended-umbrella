# Changelog

All notable changes to the Extended Umbrella package for Litecoin Space are documented here.

## 3.3.1-umbrel.6 — 2026-08-10

### Changed

- Standardizes the package directory and app ID as `extended-umbrella-litecoin-litecoinspace`.
- Preserves the frontend and backend images, MariaDB data, explorer cache, dependencies, and Electrs provider contract unchanged.
- The former `extended-umbrella-litecoinpool` identity had no installations and is intentionally not retained as a duplicate catalog entry.

## 3.3.1-umbrel.1 — 2026-08-08

### Added

- Packages the Litecoin Foundation's Litecoin Space frontend and backend from independently built, immutable multi-architecture images.
- Connects the explorer to Extended Umbrella Litecoin Core and Fulcrum LTC.
- Adds MariaDB persistence, unprivileged data-directory initialization, health checks, memory-aware backend limits, and Litecoin Space branding.
