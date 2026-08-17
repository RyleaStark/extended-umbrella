# Changelog

## 0.4.0.rc33-umbrel.1 — 2026-08-17

- Pin immutable multi-architecture lnSwitchboard RC33 image `sha256:d9e8dfee8766439d2dadd96e0a0dad4b1aa93c70153e628e2f1ae690f1518147`.
- Preserve an authenticated, registered Tailscale node when the short-lived browser flow expires.
- Continue cancelling abandoned login flows that never authenticated.

## 0.4.0.rc32-umbrel.1 — 2026-08-13

- Pin immutable multi-architecture lnSwitchboard RC32 image `sha256:20f268d81cac7006653af38c801502b5a5daafa2844593f8096a0803c700d8c6`.
- Restore bottom padding beneath the compact iOS navigation controls.
- Prevent horizontal page scrolling from the mobile content inset.

## 0.4.0.rc31-umbrel.1 — 2026-08-13

- Pin immutable multi-architecture lnSwitchboard RC31 image `sha256:2269585f8b6f98ba0bef06ed57878fa3acf070ccc368ee9f990122a560659859`.
- Add durable, operation-correlated Tailscale lifecycle recovery with identity-bound destructive operations and observational refresh.
- Keep Cloudflare, Tailscale Funnel, and zrok isolated to the public listener on port 21212 while App Proxy retains private administration on port 22121.
- Include the RC31 navigation, flattened page, unified address-creation, provider copy, request-log, and badge UI updates.

## 0.4.0.rc30-umbrel.1 — 2026-08-12

- Reconcile Refresh status with provider-native zrok share inventory for the exact environment, public target, proxy mode, and expected endpoint.
- Bind destructive disconnect commands and acknowledgements to the persisted reserved namespace and name.
- Recover interrupted `starting` state and retain explicit cleanup authority when compensation cannot finish.
- Scope share cleanup by zrok environment ID and endpoint so another deployment using the same account and internal target cannot be deleted.
- Preserve tokenless active state and the isolated secretless public listener on port 21212.

## 0.4.0.rc29-umbrel.1 — 2026-08-12

- Fix deterministic zrok Refresh status failures caused by deleting the current status snapshot before the sidecar consumed the command.
- Correlate refresh acknowledgements to the exact operation and reserved zrok identity, while tolerating transient missing or malformed snapshots without disconnecting a healthy share.
- Stop persisting subordinate zrok share tokens and migrate legacy active state to the non-secret endpoint-and-identity record during recovery.
- Preserve zrok's isolated route to the secretless public listener on port 21212.

## 0.4.0.rc22-umbrel.3 — 2026-08-09

- Retire validated App Proxy publication temporaries through a root-private crash-recovery directory while holding the opened inode across the atomic move.
- Restore and preserve a substituted pathname entry rather than deleting it, and unlink only after verifying the moved object against the held descriptor inside the private directory.
- Recover interruption after the retirement move and add deterministic final-replacement and retirement-recovery regressions.

## 0.4.0.rc22-umbrel.2 — 2026-08-09

- Recover the exact dot-prefixed App Proxy publication temporary emitted when the guarded writer is interrupted after file fsync and before atomic replacement.
- Retire authority-bound legacy SQLite journal/WAL/SHM compatibility links through a root-private, crash-recoverable directory while holding the validated inode open, preventing a final pathname replacement from being deleted.
- Add exact-writer crash recovery, retirement-interruption recovery, replacement-race, metadata, hardlink, symlink, and outside-mutation regressions.

## 0.4.0.rc22-umbrel.1 — 2026-08-09

- Pin lnSwitchboard RC22 by immutable multi-architecture OCI index digest.
- Split the administration and public listeners into separate least-privilege containers joined only by a hardened Unix socket.
- Keep operational SQLite, LND macaroons, provider credentials, and connector state out of the Internet-facing public process.
- Route Cloudflare Mesh and Tailscale Funnel only through the bounded public listener on port 21212.
- Preserve the rollback-compatible historical database/key authority and transactional migration recovery.
- Verify every privileged writable bind mount by descriptor identity against a read-only host view before initialization, and publish the App Proxy privacy override atomically.
- Avoid rollback compatibility links for transient SQLite journal/WAL/SHM files and retire legacy links only when a validated schema-v2 marker and digest-matched archive bind that exact sidecar, so RC21 rollback/re-upgrade cannot strand a dangling journal path.
- Recover bounded, root-owned App Proxy privacy-config publication temporaries after interruption while rejecting symlinks, hardlinks, malformed names, metadata, and content.

All notable changes to the Extended Umbrella package for lnSwitchboard are documented here.

## 0.4.0.rc21-umbrel.1 — 2026-08-09

### Fixed

- Pins the immutable multi-platform RC21 image built from merged source `8369b7305a9300ed10d23af7be96be4434718bf6` at OCI index `sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765` for both migration and application services.
- Enforces byte-for-byte canonical OAuth callbacks before production listeners open, including WHATWG numeric-host, malformed IDNA, authority, port, path, delimiter, Unicode, and browser-normalization rejection.
- Keeps webhook payloads, destinations, signing material, payer data, payment requests, preimages, remote bodies, raw exceptions, and payload-derived identity fields out of operator history while reconstructing stable retries from current authoritative invoice/address state.
- Applies configured retention to terminal invoice and webhook history without deleting pending retry authority, and creates or repairs SQLite, macaroon, connection-key, and Nostr signer files with owner-only permissions.
- Refreshes durable migration recovery authorities after rollback/re-upgrade so a completed marker cannot restore a stale credential generation.

## 0.4.0.rc20-umbrel.1 — 2026-08-08

### Fixed

- Pins the immutable multi-platform RC20 image built from exact merged source `ef3e3354f0944844d12c48f10b2b2a88decb22fd`; RC20 replaces persisted webhook destinations with non-reversible references, strips signing headers, exception text, response bodies, and payloads from operator-visible history, and idempotently re-scrubs legacy rows after rollback/re-upgrade.
- Makes OAuth privacy application-owned and cross-platform: query-bearing callbacks are restricted to exact portable IP-loopback URLs, remote callbacks require a clean HTTPS fragment-only page, the static receiver has no query fallback or network access, and production application access logs remain disabled. These guarantees do not depend on Umbrel App Proxy, Caddy, NGINX, or another host-specific proxy.
- Keeps remote OAuth unavailable by default with the source placeholder callback until a real HTTPS fragment callback page and OAuth client are explicitly provisioned.
- Enables the authoritative `UMBREL` deployment mode so authenticated App Proxy requests from remote clients reach the administration listener. A root-owned read-only proxy override keeps Umbrel's inherited proxy silent and the OAuth completion API authenticated as package-specific defense in depth, not as the portable security boundary.
- Preserves rollback compatibility with interim RC15 packages through exact relative links to the canonical `data/secrets` state tree, so records remain live across upgrade, rollback, and re-upgrade.
- Uses atomic no-overwrite state commits and a root-owned, fsynced transaction manifest that binds every canonical database, key, sidecar, and exact archive destination before destructive cleanup. Recovery rejects mixed credential generations, resumes every marker/commit/archive boundary, preserves rollback-created state, rejects hard links and untrusted reserved paths, and masks connector state from the privileged migrator.
- Grants the Cloudflare Mesh sidecar the exact supplementary group needed to read its UID/GID 1000 token handoff without broadening application access to Mesh private state.

## 0.4.0.rc15-umbrel.8 — 2026-08-08

### Fixed

- Restores the RC12 persistent state contract at `data/secrets:/app/secrets`, so existing lnSwitchboard databases and secret state remain visible after container replacement.
- Keeps Tailscale control and status files under the same historical persistent secrets tree.
- Adds a network-isolated, least-privilege state migrator for records written by interim `umbrel.2` through `umbrel.7` packages. Original files are archived after SQLite integrity verification; divergent historical and interim databases fail closed without changing either copy.
- Adds an executable upgrade regression that seeds real RC12 records and verifies the exact RC15 image can still read them through the rendered package mount.

## 0.4.0.rc15-umbrel.7 — 2026-08-08

### Fixed

- Uses Umbrel's transitive Bitcoin dependency export `APP_BITCOIN_NETWORK` when locating the invoice and readonly macaroons. Fresh installs and ordinary Umbrel updates no longer depend on an undeclared `BITCOIN_NETWORK` shell variable.

## 0.4.0.rc15-umbrel.6 — 2026-08-08

### Security

- Replaces the broad read-only LND data-directory mount with three exact file mounts: the TLS certificate, invoice macaroon, and readonly macaroon. The admin macaroon and all unrelated Lightning node data are no longer visible inside lnSwitchboard.

## 0.4.0.rc15-umbrel.5 — 2026-08-08

### Fixed

- Replaces obsolete `LNS_*` and legacy OAuth callback environment names with the RC15 configuration contract, allowing Umbrel's app proxy host to reach the administration listener instead of receiving HTTP 400.
- Uses the invoice and readonly LND macaroons required by RC15 instead of exposing the unrestricted admin macaroon to the application.
- Removes the application's unnecessary mounts of Tailscale's private node state and LocalAPI socket; browser-controlled Tailscale operations remain isolated to the reviewed control/status file protocol.

## 0.4.0.rc15-umbrel.4 — 2026-08-08

### Fixed

- Runs the reviewed lnSwitchboard Tailscale supervisor as the sidecar entrypoint instead of bypassing it with Tailscale's generic `containerboot` command.
- Uses unprivileged userspace networking with every Linux capability dropped, no TUN device, and `no-new-privileges`, eliminating the kernel-network permission restart loop seen on the live Umbrel host.
- Shares the application's private Tailscale control/status directory with the supervisor so browser-executed login, Funnel, and disconnect commands work without a Docker socket.
- Upgrades and pins the current Tailscale `v1.102.2` multi-platform index and disables Tailscale client log uploads with `TS_NO_LOGS_NO_SUPPORT=true`.
- Corrects the packaged supervisor hook filename and adds a local socket health check.

## 0.4.0.rc15-umbrel.3 — 2026-08-08

### Fixed

- Updates the container health check from the removed `/health` route to RC15's admin-only `/api/health` endpoint. The application was running and connected to LND, but the stale route returned 404 and kept App Proxy and Mesh blocked behind an unhealthy dependency.

## 0.4.0.rc15-umbrel.2 — 2026-08-08

### Fixed

- Mounts the persistent Umbrel application data directory at lnSwitchboard's current writable `/app/secrets` state path. RC15 previously mounted it only at the obsolete `/app/data` path, so startup failed while creating the database log directory.
- Removes the obsolete `LNS_DATA_DIR` compatibility variable now that the package follows RC15's explicit state-path contract.

## 0.4.0.rc15-umbrel.1 — 2026-08-08

### Fixed

- Uses Umbrel's actual Lightning dependency export, `APP_LIGHTNING_NODE_IP`, for `LND_HOST`. The previous `LND_IP` reference expanded to an empty value during an update, causing RC15 to restart continuously with `LND_HOST` missing.

## 0.4.0.rc15 — 2026-08-08

### Fixed

- Updates lnSwitchboard to verified multi-architecture RC15: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc15@sha256:9ee6cdea6deaa25b88efde9c5e4309f4862cfaf6dd1b76429053610dcd193857`.
- Includes the repaired, verified Tailscale `v1.88.4` multi-platform index pin from the RC14 package hotfix so failed RC14 updates can recover directly to RC15.

## 0.4.0.rc14-umbrel.1 — 2026-08-08

### Fixed

- Repairs RC14 installs and updates after Docker Hub removed the previously pinned Tailscale `v1.88.4` manifest. The package now pins the currently published, verified multi-architecture index `tailscale/tailscale:v1.88.4@sha256:360e10ad95ad03950f66df03e0dab66287f9f89076ee4012d50bc6adceafcdf3`.
- The lnSwitchboard application remains the immutable RC14 image at `sha256:80659be0e48830e008524e75785b1c9b688c7ad45acb1b1dbbaf60c1f9912d4b`; this is a packaging-only revision.

## 0.4.0.rc14 — 2026-08-08

### Changed

- Updates lnSwitchboard to verified multi-architecture RC14: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc14@sha256:80659be0e48830e008524e75785b1c9b688c7ad45acb1b1dbbaf60c1f9912d4b`.
- Replaces the Cloudflare Tunnel connector with a digest-pinned Cloudflare Mesh sidecar and customer-owned Worker data path.
- Adds OAuth-only Cloudflare onboarding with public-client PKCE, explicit account and zone authorization, reconnect, and local encrypted grants.
- Splits public LNURL/Nostr traffic onto the dedicated `:21212` listener while keeping administration on `:22121`.
- Adds a supervised, identity-aware Mesh token handoff that clears stale persisted registration state before enrolling a replacement node.
- Restricts the Mesh container to `/dev/net/tun`, `cap_drop: ALL`, and only `NET_ADMIN`/`NET_RAW`; no host networking, privileged mode, Docker socket, or published Mesh ports.
- Disables Worker `workers.dev` and Preview URLs and restricts Worker forwarding to LNURL-pay and Nostr discovery paths.
- Cloudflare onboarding remains disabled until the deployment supplies a registered public OAuth client ID and callback URLs.

## 0.4.0.rc12 — 2026-08-08

### Fixed

- Cloudflare domain onboarding now initializes a newly selected remotely managed tunnel whose API configuration is validly returned as `null` before its first configuration write. Previously lnSwitchboard converted this state to HTTP 502 before writing ingress, DNS, or the connector token.
- Pins the verified multi-architecture RC12 image index: `ghcr.io/ryleastark/lnswitchboard:0.4.0.rc12@sha256:7b6bc8e30e5b1ccf5cc11ee764d0503ada7717945f2f02913b2b3404dabb8561`.

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
