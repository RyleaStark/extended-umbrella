#!/usr/bin/env bash
set -euo pipefail
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc39@sha256:5cb80b766a02604ac5f190b35515a58d88a082e356676fa6e226b2e379bcf237'

docker run --rm -i \
  --user 1000:1000 \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=1777 \
  -e LND_HOST=127.0.0.1 \
  -e LND_TLS_PATH=/tmp/missing.cert \
  -e DATA_STORE_PATH=/tmp/lnswitchboard.db \
  -e 'TRUSTED_HOSTS=*' \
  --entrypoint python \
  "$APP_IMAGE" - <<'PY'
import asyncio
import os

import httpx

from backend.app import config, main


async def request(path: str) -> httpx.Response:
    main.public_app.dependency_overrides[main.require_configured_public_domain] = lambda: None
    transport = httpx.ASGITransport(app=main.public_app)
    async with httpx.AsyncClient(
        transport=transport,
        base_url="https://pay.example",
        follow_redirects=False,
    ) as client:
        return await client.get(path)


os.environ["PUBLIC_FALLBACK_MODE"] = "redirect"
os.environ["PUBLIC_FALLBACK_REDIRECT_URL"] = "https://example.com/payments"
config.get_settings.cache_clear()
redirect = asyncio.run(request("/pricing?source=wallet"))
assert redirect.status_code == 307
assert redirect.headers["location"] == "https://example.com/payments"
assert "pricing" not in redirect.headers["location"]
assert "source" not in redirect.headers["location"]

unknown_well_known = asyncio.run(request("/.well-known/unrelated"))
assert unknown_well_known.status_code == 404
assert "location" not in unknown_well_known.headers

nostr = asyncio.run(request("/.well-known/nostr.json"))
assert nostr.status_code == 200
assert "location" not in nostr.headers

os.environ["PUBLIC_FALLBACK_MODE"] = "reject"
os.environ["PUBLIC_FALLBACK_STATUS_CODE"] = "410"
os.environ.pop("PUBLIC_FALLBACK_REDIRECT_URL", None)
config.get_settings.cache_clear()
rejected = asyncio.run(request("/pricing"))
assert rejected.status_code == 410
assert rejected.text == "Public path not served"
assert "location" not in rejected.headers

included_paths = [
    getattr(route, "path", None)
    for wrapper in main.public_app.routes
    if hasattr(wrapper, "original_router")
    for route in wrapper.original_router.routes
]
assert "/.well-known/nostr.json" in included_paths
assert "/.well-known/lnurlp/{username}" in included_paths
assert main.public_app.routes[-1].path == "/{path:path}"
PY

printf 'GREEN exact_rc39_public_fallback_policy_ok\n'
