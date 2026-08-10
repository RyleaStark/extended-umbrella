# Extended Umbrella

A community Umbrel App Store maintained by [RyleaStark](https://github.com/RyleaStark).

Extended Umbrella packages pin released container images by immutable OCI index digest. Litecoin application images are published for both `linux/amd64` and `linux/arm64` and are independently checked for anonymous pulls before store publication.

## Add the store to Umbrel

Open the Umbrel App Store, choose **Community App Stores**, and add:

```text
https://github.com/RyleaStark/extended-umbrella.git
```

## Applications

| Application | Package ID | Version | UI port | Role |
| --- | --- | ---: | ---: | --- |
| [Litecoin Core](https://github.com/RyleaStark/umbrel-litecoin-core-gui) | `extended-umbrella-litecoin-core` | `0.21.5.5-umbrel.6` | `2110` | Fully validating Litecoin node and wallet RPC provider |
| [Electrs (LTC)](https://github.com/RyleaStark/umbrel-electrs-ltc) | `extended-umbrella-litecoin-electrs` | `0.9.12-umbrel.5` | `2111` | Canonical Litecoin Electrum capability provider; wallet port `51001` |
| [Fulcrum (LTC)](https://github.com/RyleaStark/umbrel-litecoin-fulcrum-gui) | `extended-umbrella-litecoin-fulcrum` | `2.1.1-umbrel.8` | `2109` | Alternative high-performance Electrum provider; wallet port `51002` |
| [ElectrumX (LTC)](https://github.com/RyleaStark/umbrel-electrumx-ltc) | `extended-umbrella-litecoin-electrumx` | `2.0.0-umbrel.3` | `2108` | Alternative lightweight Electrum provider; wallet port `51003` |
| [Litecoin Space](https://github.com/RyleaStark/umbrel-litecoinspace) | `extended-umbrella-litecoin-litecoinspace` | `3.3.1-umbrel.6` | `3012` | Self-hosted Litecoin explorer and mempool visualizer |
| [lnSwitchboard](https://github.com/RyleaStark/lnSwitchboard) | `extended-umbrella-lnswitchboard` | `0.4.0.rc22-umbrel.3` | `22121` | Self-hosted Lightning Addresses and NIP-05 identities |

## Litecoin dependency model

```text
Litecoin Core
├── Electrs (LTC) ───────────────┐
├── Fulcrum (LTC) ─ implements ──┤─ Electrs capability ─ Litecoin Space
└── ElectrumX (LTC) ─ implements ┘
```

- Every indexer depends on `extended-umbrella-litecoin-core`.
- Electrs is the canonical dependency identity.
- Fulcrum and ElectrumX implement the same capability, allowing compatible apps to use an installed alternative provider.
- Each indexer retains independent state, product identity, Local/Tor connection details, and a distinct wallet port.
- ElectrumX admin RPC `8000` is private and is never advertised as a wallet endpoint.

## Published Litecoin images

| Image | Purpose |
| --- | --- |
| `ghcr.io/ryleastark/umbrel-litecoin-core-gui` | Litecoin Core Umbrel interface |
| `ghcr.io/ryleastark/umbrel-litecoin-electrs-gui` | Electrs Umbrel interface |
| `ghcr.io/ryleastark/umbrel-electrs-ltc` | Litecoin-compatible Electrs daemon |
| `ghcr.io/ryleastark/umbrel-litecoin-fulcrum-gui` | Fulcrum Umbrel interface |
| `ghcr.io/ryleastark/umbrel-litecoin-electrumx-gui` | ElectrumX Umbrel interface |
| `ghcr.io/ryleastark/umbrel-electrumx-ltc` | Litecoin ElectrumX daemon |
| `ghcr.io/ryleastark/umbrel-litecoinspace-frontend` | Litecoin Space web application |
| `ghcr.io/ryleastark/umbrel-litecoinspace-backend` | Litecoin Space API/indexing backend |

Fulcrum itself uses the upstream `cculianu/fulcrum` image; only its Umbrel interface is published under the RyleaStark namespace.

## Release and security policy

- Store Compose references include both a semantic image tag and immutable multi-platform OCI index digest.
- GUI containers run unprivileged as `1000:1000` with production-only dependencies.
- Wallet QR codes are generated locally; connection details are not sent to third-party QR services.
- Daemon data remains under each app's `${APP_DATA_DIR}` and is not replaced during GUI-only updates.
- Package release notes explicitly call out migrations, listener changes, and preserved runtime versions.
- Publication to this store does not imply installation or deployment to an Umbrel device.

## Support and contributions

Use the application repository linked in the table for product-specific issues. Store packaging issues can be reported at [RyleaStark/extended-umbrella](https://github.com/RyleaStark/extended-umbrella/issues).

Maintained by [RyleaStark](https://github.com/RyleaStark). If the store is useful, consider starring the repository.
