#!/usr/bin/env bash
set -euo pipefail
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc16@sha256:d9309bc5183ce40740efd5ac291bf1092390570d1fd03ecba8c3761945c55f81'
docker run --rm -i --platform linux/arm64 --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
import io
import logging
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
from backend.app.webhook_dispatcher import WebhookDispatcher

secret_url='https://hooks.invalid/services/PATH-SECRET?token=QUERY-SECRET'
stream=io.StringIO()
handler=logging.StreamHandler(stream)
logger=logging.getLogger('rc16-log-redaction-fixture')
logger.handlers[:]=[handler]
logger.setLevel(logging.INFO)
logger.propagate=False

async def success(*args, **kwargs):
    return None

async def failure(*args, **kwargs):
    raise RuntimeError('exception contains PATH-SECRET and QUERY-SECRET')

async def exercise():
    ok=WebhookDispatcher(
        address_store=LNAddressStore(Path('/tmp/success.db')),
        sender=success,
        max_retries=0,
    )
    ok._logger=logger
    assert await ok._attempt_delivery(
        delivery_id=1, url=secret_url, payload={}, headers={}, attempt=1
    )
    bad=WebhookDispatcher(
        address_store=LNAddressStore(Path('/tmp/failure.db')),
        sender=failure,
        max_retries=0,
    )
    bad._logger=logger
    assert not await bad._attempt_delivery(
        delivery_id=2, url=secret_url, payload={}, headers={}, attempt=1
    )

asyncio.run(exercise())
logs=stream.getvalue()
for secret in (secret_url, 'PATH-SECRET', 'QUERY-SECRET'):
    assert secret not in logs, logs
print('GREEN exact_rc16_webhook_logs_redact_destination_secrets')
PY
