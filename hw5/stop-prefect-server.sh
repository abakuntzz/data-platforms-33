#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

PID_FILE=$HW5_HOME/prefect-server.pid

if [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2> /dev/null; then
    echo "Сервер Prefect остановлен"
else
    echo "Сервер Prefect не был запущен"
fi
rm -f "$PID_FILE"