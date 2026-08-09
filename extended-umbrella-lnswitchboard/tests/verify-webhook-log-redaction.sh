#!/usr/bin/env bash
set -euo pipefail
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc18@sha256:e8a3f17e62ae3b53166db85342fed844140719cf83449601290bbd00fa50dfa4'
docker run --rm -i --platform linux/arm64 --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
import io
import json
import logging
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
from backend.app.log_storage import InvoiceEvent, RequestLogStorage
from backend.app.outbound_security import OutboundHTTPStatusError
from backend.app.webhook_dispatcher import WebhookDispatcher

db_path=Path('/tmp/persisted-webhook-redaction.db')
storage=RequestLogStorage(db_path)
address_store=LNAddressStore(db_path)
secret_url='https://hooks.invalid/services/PERSISTED_PATH_SECRET?token=PERSISTED_QUERY_SECRET'
stream=io.StringIO()
handler=logging.StreamHandler(stream)
logger=logging.getLogger('rc18-persisted-log-redaction-fixture')
logger.handlers[:]=[handler]
logger.setLevel(logging.INFO)
logger.propagate=False

class SecretStatusError(OutboundHTTPStatusError):
    def __str__(self):
        return 'PERSISTED_EXCEPTION_SECRET'

async def sender(url, payload, headers):
    raise SecretStatusError(503, 'PERSISTED_RESPONSE_SECRET')

async def exercise():
    address=await address_store.add_address(
        local_part='pay', domain='testserver', min_sendable_sat=None,
        max_sendable_sat=None, metadata_description=None,
        success_message=None, webhook_urls=[secret_url],
    )
    created=datetime.now(tz=timezone.utc).isoformat()
    details={
        'ln_address':'pay@testserver', 'username_raw':'pay', 'domain':'testserver',
        'payment_hash':'ab'*32,
        'address_override':{'id':address['id'],'local_part':'pay','domain':'testserver'},
        'invoice':{'payment_hash':'ab'*32,'settled':True},
    }
    event=InvoiceEvent(
        id=1, username='pay', domain='testserver', ip='127.0.0.1',
        amount_msat=2000, payment_hash='ab'*32, payment_request='lnbc1tester',
        request_log_id=None, created_at=created, next_check_at=None,
        check_interval_seconds=60, expires_at=None, settled=True, expired=False,
        details=details, settled_at=None,
    )
    dispatcher=WebhookDispatcher(
        address_store=address_store, delivery_storage=storage,
        sender=sender, max_retries=0,
    )
    dispatcher._logger=logger
    assert not await dispatcher.dispatch_payment_settled(
        event=event, details=details, settled_at=datetime.now(tz=timezone.utc)
    )
    return json.dumps({
        'deliveries':await storage.list_deliveries(page=1,page_size=5),
        'attempts':await storage.list_delivery_attempts(1),
        'request_logs':await storage.get_recent(),
    },sort_keys=True)

exposed=asyncio.run(exercise())
with sqlite3.connect(db_path) as conn:
    persisted=json.dumps({
        'deliveries':conn.execute('SELECT target,headers FROM webhook_deliveries').fetchall(),
        'attempts':conn.execute('SELECT error,response_body FROM webhook_attempts').fetchall(),
        'request_logs':conn.execute("SELECT message,details FROM request_logs WHERE event='webhook_delivery'").fetchall(),
    },sort_keys=True)
for secret in ('PERSISTED_PATH_SECRET','PERSISTED_QUERY_SECRET','PERSISTED_EXCEPTION_SECRET','PERSISTED_RESPONSE_SECRET'):
    assert secret not in exposed, exposed
    assert secret not in persisted, persisted
    assert secret not in stream.getvalue(), stream.getvalue()

# Model data persisted by RC16 while the migration marker remains, and prove
# RC18 re-scrubs the history during rollback/re-upgrade.
now=datetime.now(tz=timezone.utc).isoformat()
with sqlite3.connect(db_path) as conn:
    conn.execute(
        """INSERT INTO webhook_deliveries
        (created_at,updated_at,kind,event,target,status,payload,headers,address_id,invoice_event_id,request_log_id,delivery_key)
        VALUES (?,?, 'http.webhook','payment.settled',?,'failed','{}',?,NULL,NULL,NULL,'legacy-fixture')""",
        (now,now,'https://hooks.invalid/LEGACY_PATH_SECRET?token=LEGACY_QUERY_SECRET',json.dumps({'X-LnSwitchboard-Signature':'LEGACY_SIGNATURE_SECRET'})),
    )
    legacy_id=conn.execute('SELECT last_insert_rowid()').fetchone()[0]
    conn.execute(
        "INSERT INTO webhook_attempts (delivery_id,attempted_at,attempt_number,success,error,response_body) VALUES (?,?,1,0,?,?)",
        (legacy_id,now,'LEGACY_EXCEPTION_SECRET','LEGACY_RESPONSE_SECRET'),
    )
    conn.execute(
        "INSERT INTO request_logs (timestamp,username,ip,event,status,message,details) VALUES (?,'webhook','internal','webhook_delivery','failed',?,?)",
        (now,'LEGACY_MESSAGE_SECRET',json.dumps({'target':'LEGACY_DETAILS_SECRET'})),
    )
RequestLogStorage(db_path)
with sqlite3.connect(db_path) as conn:
    legacy=json.dumps({
        'delivery':conn.execute('SELECT target,headers FROM webhook_deliveries WHERE id=?',(legacy_id,)).fetchall(),
        'attempt':conn.execute('SELECT error,response_body FROM webhook_attempts WHERE delivery_id=?',(legacy_id,)).fetchall(),
        'logs':conn.execute("SELECT message,details FROM request_logs WHERE event='webhook_delivery'").fetchall(),
    },sort_keys=True)
for secret in ('LEGACY_PATH_SECRET','LEGACY_QUERY_SECRET','LEGACY_SIGNATURE_SECRET','LEGACY_EXCEPTION_SECRET','LEGACY_RESPONSE_SECRET','LEGACY_MESSAGE_SECRET','LEGACY_DETAILS_SECRET'):
    assert secret not in legacy, legacy
print('GREEN exact_rc18_webhook_logs_rescrub_after_rollback')
PY
