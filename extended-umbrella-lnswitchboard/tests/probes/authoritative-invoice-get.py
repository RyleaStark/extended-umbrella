"""Synthetic published-image TCP proof. Never contacts a wallet/provider."""
import asyncio
import hashlib
import socket

import httpx
import uvicorn

from backend.app.main import admin_app, client_only_app, public_app, require_configured_public_domain
from backend.app.ln_client import LNClient
from backend.app.config import get_settings
from backend.app.sqlite_utils import sqlite_connection

node = {}
adds = []


async def lookup(self, payment_hash):
    if payment_hash.hex() not in node:
        raise LookupError('synthetic unknown invoice')
    return node[payment_hash.hex()]


async def add(self, *, amount_msat, memo, expiry_seconds, r_preimage):
    payment_hash = hashlib.sha256(r_preimage).hexdigest()
    adds.append(payment_hash)
    node[payment_hash] = {'r_hash': bytes.fromhex(payment_hash), 'value_msat': amount_msat,
        'creation_date': 1790000000, 'expiry': expiry_seconds, 'state': 'OPEN', 'settled': False,
        'amt_paid_msat': 0, 'settle_date': 0, 'payment_request': 'lnbc1-synthetic-private'}
    return {'r_hash': bytes.fromhex(payment_hash), 'payment_request': 'lnbc1-synthetic-private'}


LNClient.lookup_invoice = lookup
LNClient.create_invoice = add


def rows():
    with sqlite_connection(get_settings().data_store_path) as db:
        return {table: [tuple(row) for row in db.execute('SELECT * FROM ' + table)]
                for table in ('api_client_requests', 'invoice_events', 'connection_secrets')}


async def main():
    servers, tasks, bases = [], [], []
    public_app.dependency_overrides[require_configured_public_domain] = lambda: None
    try:
        for app in (admin_app, client_only_app, public_app):
            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            sock.listen(128)
            bases.append('http://127.0.0.1:' + str(sock.getsockname()[1]))
            server = uvicorn.Server(uvicorn.Config(app, log_level='critical', lifespan='off', proxy_headers=False))
            servers.append(server)
            tasks.append(asyncio.create_task(server.serve(sockets=[sock])))
        for _ in range(100):
            if all(server.started for server in servers):
                break
            await asyncio.sleep(0.02)
        else:
            raise AssertionError('synthetic TCP listeners did not start')
        async with httpx.AsyncClient(timeout=3, trust_env=False) as client:
            issued_response = await client.post(bases[0] + '/api/client-credentials', json={
                'domain': 'pay.example.com', 'webhook_url': 'https://billing.example.com/native-callback',
                'webhook_secret': 'synthetic-webhook-secret-00000000',
                'scopes': ['addresses:create', 'addresses:read_own', 'invoices:create']})
            assert issued_response.status_code == 201, issued_response.status_code
            issued = issued_response.json()
            headers = {'Authorization': 'Bearer ' + issued['token'], 'Idempotency-Key': 'address-request-1'}
            address_response = await client.post(bases[1] + '/api/client/v1/addresses', headers=headers,
                json={'external_user_ref': 'opaque-synthetic-user-0001'})
            assert address_response.status_code == 201
            address = address_response.json()
            prefix = '/api/client/v1/addresses/' + address['address_id'] + '/invoices'
            headers['Idempotency-Key'] = 'invoice-request-1'
            created = await client.post(bases[1] + prefix, headers=headers,
                json={'quote_id': 'quote-synthetic-1', 'amount_msat': 2000, 'expiry_days': 14})
            assert created.status_code == 201, created.status_code
            invoice = created.json()
            path = prefix + '/' + invoice['payment_hash']
            # GET needs no idempotency header and must not allocate new invoices.
            headers.pop('Idempotency-Key')
            before = rows()
            response = await client.get(bases[1] + path, headers=headers)
            assert response.status_code == 200, ('authoritative GET absent', response.status_code)
            expected = {'payment_hash': invoice['payment_hash'], 'address_id': address['address_id'],
                'ln_address': address['ln_address'], 'client_id': issued['client_id'], 'quote_id': 'quote-synthetic-1',
                'amount_msat': 2000, 'created_at': 1790000000, 'expires_at': 1791209600,
                'settled': False, 'paid_msat': 0, 'settled_at': 0}
            assert response.json() == expected
            assert response.headers['cache-control'] == 'no-store, private'
            node[invoice['payment_hash']].update(state='SETTLED', settled=True, amt_paid_msat=2500,
                settle_date=1790000100, r_preimage=b'never-return-this', htlcs=[{'secret': 'never'}])
            paid = await client.get(bases[1] + path, headers=headers)
            assert paid.json() == {**expected, 'settled': True, 'paid_msat': 2500, 'settled_at': 1790000100}
            assert rows() == before
            assert len(adds) == 1
            assert (await client.get(bases[1] + path)).status_code == 401
            assert (await client.get(bases[2] + path, headers=headers)).status_code == 404
            node[invoice['payment_hash']]['value_msat'] = 2001
            assert (await client.get(bases[1] + path, headers=headers)).status_code == 503
            assert (await client.delete(bases[0] + '/api/client-credentials/' + issued['client_id'])).status_code == 204
            assert (await client.get(bases[1] + path, headers=headers)).status_code == 401
            assert len(adds) == 1
        print('GREEN exact_published_image_authoritative_invoice_get_tcp_contract_and_no_writes')
    finally:
        for server in servers:
            server.should_exit = True
        await asyncio.gather(*tasks, return_exceptions=True)
        public_app.dependency_overrides.clear()


asyncio.run(main())
