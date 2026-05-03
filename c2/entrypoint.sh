#!/bin/sh
set -e

CONFIG_DIR=/root/.sliver-client/configs
mkdir -p "$CONFIG_DIR"

# Start server daemon in background
/usr/local/bin/sliver-server daemon &

# Wait until the multiplayer port is accepting connections
echo "[c2] Waiting for sliver-server on :31337..."
until nc -z 127.0.0.1 31337 2>/dev/null; do sleep 1; done
echo "[c2] Server ready."

# Generate operator config once — persisted in the configs volume
if [ -z "$(ls "$CONFIG_DIR"/*.cfg 2>/dev/null)" ]; then
    echo "[c2] Generating operator config..."
    /usr/local/bin/sliver-server operator \
        --name operator \
        --lhost 127.0.0.1 \
        --lport 31337 \
        --permissions all \
        --save "$CONFIG_DIR"
    echo "[c2] Config saved — 'docker exec -it dragonrx_c2 sliver' is ready."
fi

wait
