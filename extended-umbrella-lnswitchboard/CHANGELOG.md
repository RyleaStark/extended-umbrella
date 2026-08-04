# Changelog

All notable changes to the Extended Umbrella package for lnSwitchboard are documented here.

## 0.3.1 — 2026-08-03

### Changed

- Updated lnSwitchboard from 0.2.3 to 0.3.1.
- Pinned the verified GHCR multi-architecture image index at `sha256:4e17638594ca50f6f868aef2db50e09479e3d90247d5dd75e2b3ac07a827198d`.
- Refreshed the application, Python, Node.js, and TypeScript dependency toolchains.
- Migrated production frontend type-checking and builds to TypeScript 7.
- Added Umbrel-compatible trusted-proxy configuration for private container networks while retaining support for Umbrel and user-configured public hostnames.

### Security

- Hardened forwarding-header and Host validation.
- Restricted administrative CORS behavior.
- Added default-deny validation for private webhook and Nostr relay destinations.
- Disabled outbound redirect following and environment-proxy inheritance for webhook delivery.
- Updated the container to use a non-root runtime and immutable base-image inputs.

### Reliability

- Improved LND protobuf compatibility and connection handling.
- Added explicit Nostr acknowledgement validation.
- Improved SQLite connection lifecycle handling.
- Strengthened multi-architecture image publication and cross-registry verification.

### Upgrade notes

- Existing lnSwitchboard data remains in `${APP_DATA_DIR}/data/secrets` and is reused automatically.
- No manual database migration is required.
