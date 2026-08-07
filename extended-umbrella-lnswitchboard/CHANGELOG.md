# Changelog

All notable changes to the Extended Umbrella package for lnSwitchboard are documented here.

## 0.4.0.rc2 — 2026-08-07

### Changed

- Updates the existing `extended-umbrella-lnswitchboard` app in place to the verified multi-architecture RC index `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc2@sha256:6cea4bb09fafc4b41eb5975edeb2c20ee73e240501962b9bc367baa9172c2a28`.
- Enables Cloudflare API-token and Tailscale CLI onboarding from HTTP or HTTPS administration; deployment security is operator-managed rather than enforced as an Umbrel-specific prerequisite.

### Upgrade notes

- Existing database, secrets, connector state, and public-listener routing remain unchanged.
- Installation and upgrade do not initiate Cloudflare or Tailscale authorization.

## 0.4.0.rc1 — 2026-08-07

### Changed

- Updates the existing `extended-umbrella-lnswitchboard` app in place to the verified multi-architecture RC index `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc1@sha256:96acfba538a3ed2dc8f342f4b6a98a31902f4582f86e9f63947134f162d0245d`.
- Adds split listeners: authenticated Umbrel administration remains internal on `22121`; the route-restricted public listener is host-published on `21212` for self-hosted reverse-proxy/direct publication.
- Adds Cloudflared and userspace-only Tailscale Funnel sidecars, both restricted to the public listener.
- Persists Cloudflare token, Tailscale state, and private supervisor control/status artifacts under `${APP_DATA_DIR}/data/connectors` rather than Docker named volumes.

### Upgrade notes

- The existing database and secrets at `${APP_DATA_DIR}/data/secrets` remain in place; provider tables are initialized additively.
- Existing reverse proxies should target `:21212` for public LNURL/NIP-05 endpoints, never the Umbrel administration port `:22121`.
- Installation and upgrade do not initiate Cloudflare or Tailscale authorization.

## 0.3.2 — 2026-08-03

### Changed

- Updated lnSwitchboard from 0.3.1 to 0.3.2.
- Pinned the verified GHCR multi-architecture image index at `sha256:7a91c256a69b218adcaa30b4f52315577e6966cde7ffe702bb95c4e26a07fc83`.
- Replaced the dashboard invoice activity visualization with Dither Kit.
- Added selectable 14-day Sats routed, Invoices paid, and Invoices created metrics.
- Added keyboard-accessible metric tabs and a screen-reader-readable date/value table.

### Upgrade notes

- Existing lnSwitchboard data remains in `${APP_DATA_DIR}/data/secrets` and is reused automatically.
- The existing database is indexed automatically for created-invoice activity queries.
- No manual migration is required.

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
