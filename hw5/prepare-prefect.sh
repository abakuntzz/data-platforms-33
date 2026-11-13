#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

if [ ! -x "$HW4_RUNTIME/python/bin/python3.11" ] || [ ! -x "$SPARK_HOME/bin/spark-submit" ]; then
    echo "Не найдены Spark или Python из ДЗ4 в $HW4_RUNTIME, сначала выполните hw4/prepare-spark.sh" >&2
    exit 1
fi

mkdir -p "$HW5_HOME" "$PREFECT_HOME"

if [ ! -x "$HW5_VENV/bin/python" ]; then
    "$HW4_RUNTIME/python/bin/python3.11" -m venv "$HW5_VENV"
fi

"$HW5_VENV/bin/pip" install --quiet "prefect==3.9.2"

prefect version
python -c "import pyspark; print('pyspark', pyspark.__version__)"
