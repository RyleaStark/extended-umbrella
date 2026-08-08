# Changelog

All notable changes to the Extended Umbrella package for lnSwitchboard are documented here.

## 0.4.0.rc11 — 2026-08-08

### Fixed

- Updates the existing package to verified multi-architecture RC11: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc11@sha256:996e6bb067617717f04137745f3152734bc5a46426c34cfc55fe13f414fc3a81`.
- Tailscale disconnect/refresh no longer jam when the device key has expired: an unauthenticated node skips Funnel reset and logout and always completes teardown, so the operator can re-authenticate. Live nodes keep the fail-closed disconnect.
- Public endpoint hardening: rate-limit identity now walks proxy chains right-to-left across trusted hops; forwarded LNURL callback/verify fetches require public destinations with pinned DNS, no redirects, and bounded responses; verify errors no longer echo internals.
- Cloudflare provisioning writes the two published application routes and lets Cloudflare judge existing apex DNS.
- Visual polish: slimmer dashboard metric cards, bare page headers, and no stray settings-tab scrollbar.

### Upgrade notes

- The packaged Tailscale supervisor hook is synced with the RC11 disconnect fix; the update restarts the sidecar with the fixed logic.

## 0.4.0.rc10 — 2026-08-08

### Changed

- Updates the existing package to verified multi-architecture RC10: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc10@sha256:5e41e96658bb7ce73a79d7ddcb931d716a80bc1f4ceafeedb61792348e8e1833`.
- Cloudflare setup now selects an authorized DNS zone and uses its apex for Lightning Addresses; it configures the existing Zero Trust tunnel with only the LNURL-pay and NIP-05 Public Hostname paths.

### Upgrade notes

- Existing apex DNS records are never replaced. The package retains its public listener `21212` and private administration listener `22121` boundaries.

## 0.4.0.rc9 — 2026-08-08

### Fixed

- Updates the existing package to verified multi-architecture RC9: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc9@sha256:f557a9a76d9c08a2326fe5203210a69e374a734af6d0233dcd7b10e84851050b`.
- Corrects Cloudflare authorization for valid scoped user tokens that can directly access the selected tunnel but cannot enumerate every account, and clarifies tunnel UUID versus connector-token setup.
- Warns when the registered Tailscale node has key expiry enabled, including its remaining reconnect interval.

### Upgrade notes

- Funnel continues to expose only `:443 → 127.0.0.1:21212`; administration on port `22121` remains unavailable through Funnel.

## 0.4.0.rc8 — 2026-08-07

### Changed

- Updates the existing package to verified multi-architecture RC8: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc8@sha256:2970e4a88a5521577b1a2f39256bb592db533f518512a1f4621da0eed8a4c21d`.
- Adds staged Cloudflare Tunnel setup with explicit user API-token guidance and token-derived zone selection, alongside improved mobile viewport sizing, compact dashboard metrics, and a centered footer.

### Upgrade notes

- Funnel continues to expose only `:443 → 127.0.0.1:21212`; administration on port `22121` remains unavailable through Funnel.

## 0.4.0.rc7 — 2026-08-07

### Changed

- Updates the existing package to verified multi-architecture RC7: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc7@sha256:7bdbe8e77c2d56bf473c20c92be78bfaf792a09d1976db2e909071e63c3e650d`.
- Refines the administration experience on desktop and mobile: flatter connector setup, a compact footer, solid app background, visible mobile navigation dismissal, responsive dialogs/tabs, clearer retry states, and safer masked secret inputs.

### Upgrade notes

- Funnel continues to expose only `:443 → 127.0.0.1:21212`; administration on port `22121` remains unavailable through Funnel.

## 0.4.0.rc6 — 2026-08-07

### Fixed

- Updates the existing package to verified multi-architecture RC6: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc6@sha256:cf13af45d8d0375651e7a4388af4f1424c70384ccad2996a01f3d2a3e19a2448`.
- Makes LNURL callbacks HTTPS for active public provider domains such as Tailscale Funnel hostnames, even though Funnel proxies to the local public listener over HTTP.

### Upgrade notes

- Funnel continues to expose only `:443 → 127.0.0.1:21212`; administration on port `22121` remains unavailable through Funnel.

## 0.4.0.rc5 — 2026-08-07

### Changed

- Updates the existing package to the verified multi-architecture RC5 index `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc5@sha256:0adb31170ba1645f5746114793c26a7a9be9a7b7d9479ddf31b522e716ee4f6b`.
- Does not advertise or require `tag:lnswitchboard`; the tailnet operator decides whether and how to tag the node and grant Funnel policy.

### Upgrade notes

- The existing userspace-only, UID/GID `1000:1000` Tailscale runtime and persisted application data remain unchanged.

## 0.4.0.rc4 — 2026-08-07

### Fixed

- Bumps the existing package manifest version so Umbrel's web manager detects this connector-runtime update over RC3.
- Runs the capability-free userspace Tailscale sidecar, its state/control/status directories, and socket tmpfs as UID/GID `1000:1000`; removes the failing runtime `chown`.

### Upgrade notes

- The pinned lnSwitchboard `0.4.0.rc3` image and existing app data are unchanged; this is a package/runtime-only update.

## 0.4.0.rc3 — 2026-08-07

### Fixed

- Updates the existing `extended-umbrella-lnswitchboard` app in place to the verified multi-architecture RC index `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc3@sha256:2f40586aa9ce583a48177d0d53d85010e0ef4361274d471a52386f3e5b9f3351`.
- Packages the Tailscale supervisor in Umbrel's whitelisted `hooks/` directory and mounts that copied executable, fixing the missing sidecar caused by an omitted root-level helper file.
- Runs the userspace-only Tailscale sidecar and its state/socket/control artifacts as UID/GID `1000:1000`; this avoids forbidden runtime ownership changes under the intentionally capability-free container.
- Configures an existing Cloudflare account/tunnel ID with current Cloudflare One connector API-token guidance; the existing tunnel is never created or deleted.

### Upgrade notes

- Updating recreates the previously `Created` Tailscale service with the packaged supervisor; no provider login is initiated.
- Existing database, secrets, connector state, and listener routing remain unchanged.

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
