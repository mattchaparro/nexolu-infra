#!/bin/sh
# Crea en Sentry el dashboard definido en dashboard-pos.json.
# Uso: SENTRY_USER_TOKEN=... ./crear-dashboard.sh
# Requiere un token PERSONAL con scope org:read (los tokens de organizacion
# sntrys_ solo sirven para subir source maps y Sentry los rechaza aqui).
set -e
: "${SENTRY_USER_TOKEN:?Falta SENTRY_USER_TOKEN}"
cd "$(dirname "$0")"
curl -sS -X POST "https://us.sentry.io/api/0/organizations/renovacode/dashboards/" \
  -H "Authorization: Bearer $SENTRY_USER_TOKEN" \
  -H "Content-Type: application/json" \
  --data @dashboard-pos.json
echo
