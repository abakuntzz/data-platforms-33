#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

bash prepare-prefect.sh
bash load-data.sh
bash start-prefect-server.sh
bash run-flow.sh

echo "ДЗ5 выполнено"
