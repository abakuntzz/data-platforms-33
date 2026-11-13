#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

ssh -i ~/.ssh/id_ed25519 -N -o ExitOnForwardFailure=yes \
    -L "$METASTORE_LOCAL_PORT:127.0.0.1:$METASTORE_PORT" \
    "hadoop@$NAMENODE_HOST" &
TUNNEL_PID=$!

trap 'kill $TUNNEL_PID 2> /dev/null' EXIT

sleep 3
if ! kill -0 "$TUNNEL_PID" 2> /dev/null; then
    echo "Не удалось открыть туннель до Metastore на $NAMENODE_HOST" >&2
    exit 1
fi

python flow.py
