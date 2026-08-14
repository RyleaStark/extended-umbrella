#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE="$ROOT/docker-compose.yml"
MANIFEST="$ROOT/umbrel-app.yml"

grep -Fq 'MWEB_ENABLED: "true"' "$COMPOSE"
grep -Fq 'MWEB_API_URL: "https://litecoinspace.org/api/v1/mweb"' "$COMPOSE"
grep -Fq 'MWEB_TIMEOUT_MS: "15000"' "$COMPOSE"
grep -Fq 'http://localhost:8999/api/v1/mweb/sync/status' "$COMPOSE"
grep -Fq '"indexed":true' "$COMPOSE"
grep -Fq 'umbrel-litecoin-ltcspace-frontend:v3.3.1-umbrel.5@sha256:da9b0d68049f106383af0f638213cd6fc84b5dbc8f0bcb702a955498d859cb20' "$COMPOSE"
grep -Fq 'umbrel-litecoin-ltcspace-backend:v3.3.1-umbrel.5@sha256:02d923269eeed1316ef28320ac674c740b1a43a10f7afc1fd89810e0c2576519' "$COMPOSE"
grep -Fq 'version: "3.3.1-umbrel.9"' "$MANIFEST"

printf '%s\n' 'Litecoin Space MWEB package contract: OK'
