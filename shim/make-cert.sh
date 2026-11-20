#!/bin/bash
# Make the self-signed certificate the shim presents on :443.
#
#   ./make-cert.sh          # once
#   FORCE=1 ./make-cert.sh  # regenerate
#
# The app talks HTTPS to app.imdb.com and api.imdbws.com (discovered from the
# ClientHellos captured on :443), so port 80 alone can never answer a title tap.
# Whether the device accepts this certificate without a trust profile is exactly
# what the first tap after starting the 443 listener tests: if requests appear
# in the log, no profile is needed; if the handshake is refused, the device
# needs the CA installed (a device change that has to be agreed first).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/certs"
PEM="$DIR/imdb-shim.pem"
KEY="$DIR/imdb-shim.key"

mkdir -p "$DIR"
if [ -f "$PEM" ] && [ -f "$KEY" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "already present: $PEM (FORCE=1 to regenerate)"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$KEY" -out "$PEM" \
  -subj "/CN=app.imdb.com" \
  -addext "subjectAltName=DNS:app.imdb.com,DNS:api.imdbws.com,DNS:imdb.com,DNS:www.imdb.com,DNS:secure.imdb.com,DNS:sg.media-imdb.com,DNS:ia.media-imdb.com,DNS:ios-app-config.media-imdb.com,DNS:m.media-amazon.com" \
  2>/dev/null

chmod 600 "$KEY"
echo "wrote $PEM and $KEY"
openssl x509 -in "$PEM" -noout -subject -dates
