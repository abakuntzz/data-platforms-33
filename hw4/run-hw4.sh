#!/usr/bin/env bash
# Полное выполнение ДЗ4 на edge под team.
set -euo pipefail

cd "$(dirname "$0")"
bash prepare-spark.sh
bash load-data.sh
bash run-spark.sh colours_report.py
bash verify-report.sh
echo "ДЗ4 выполнено: данные загружены, таблица записана и проверена через Hive"
