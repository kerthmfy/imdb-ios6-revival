#!/bin/bash
# Start the app.imdb.com shim. Port 80 is what the device needs; 8080 works for
# local testing without root.
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
cd "$(dirname "$0")" || exit 1
exec python3 server.py --host "$HOST" --port "$PORT"
