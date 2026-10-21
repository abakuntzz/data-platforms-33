#!/usr/bin/env bash
# Проверка окружения; таблицы ДЗ3 только читаются.
set -euo pipefail

cd "$(dirname "$0")"
exec bash run-spark.sh check_spark.py
