#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

LOG=$HW5_HOME/prefect-server.log
PID_FILE=$HW5_HOME/prefect-server.pid

if curl -s "$PREFECT_API_URL/health" > /dev/null; then
    echo "Сервер Prefect уже запущен: $PREFECT_API_URL"
    exit 0
fi

nohup prefect server start > "$LOG" 2>&1 &
echo $! > "$PID_FILE"


for i in $(seq 1 60); do
    if curl -s "$PREFECT_API_URL/health" > /dev/null; then
        echo "Сервер Prefect запущен: http://$PREFECT_SERVER_API_HOST:$PREFECT_SERVER_API_PORT"
        exit 0
    fi
    sleep 2
done

echo "Сервер Prefect не ответил за 2 минуты, последние строки лога $LOG:" >&2
tail -20 "$LOG" >&2
exit 1
