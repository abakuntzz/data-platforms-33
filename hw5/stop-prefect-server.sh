#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

PID_FILE=$HW5_HOME/prefect-server.pid

if [ ! -f "$PID_FILE" ]; then
    echo "Сервер Prefect не был запущен"
    exit 0
fi

server_pid=$(cat "$PID_FILE")
server_args=()
if [[ "$server_pid" =~ ^[1-9][0-9]*$ ]] \
    && mapfile -d '' -t server_args 2> /dev/null < "/proc/$server_pid/cmdline" \
    && [ "${#server_args[@]}" -ge 4 ] \
    && [ "${server_args[-4]}" = "$HW5_VENV/bin/python3.11" ] \
    && [ "${server_args[-3]}" = "$HW5_VENV/bin/prefect" ] \
    && [ "${server_args[-2]}" = server ] \
    && [ "${server_args[-1]}" = start ] \
    && kill "$server_pid" 2> /dev/null; then
    stop_deadline=$((SECONDS + 30))
    while kill -0 "$server_pid" 2> /dev/null; do
        if [ "$SECONDS" -ge "$stop_deadline" ]; then
            echo "Сервер Prefect не остановился за 30 секунд" >&2
            exit 1
        fi
        sleep 1
    done
    echo "Сервер Prefect остановлен"
else
    echo "PID-файл устарел: сервер Prefect из $HW5_VENV не найден"
fi
rm -f "$PID_FILE"
