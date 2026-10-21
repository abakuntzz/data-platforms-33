#!/usr/bin/env bash
# Запускать на edge под team. Окружение ДЗ4 хранится отдельно от Hadoop и Hive.
set -euo pipefail

cd "$(dirname "$0")"
source ../hw1/cluster.conf
[[ $(id -un) == "$SSH_USER" ]] || { echo "Запускайте под $SSH_USER на edge" >&2; exit 1; }
sudo -n test -d /home/hadoop/hadoop-3.4.0/etc/hadoop || { echo "На edge нужен Hadoop из ДЗ1" >&2; exit 1; }

RUNTIME=/home/hadoop/hw4-spark
SPARK_NAME=spark-3.5.9-bin-hadoop3
SPARK_URL="https://dlcdn.apache.org/spark/spark-3.5.9/$SPARK_NAME.tgz"
SPARK_SHA512=66097faf48b12f8673dc13256a44d731c27c86a5831cd8ca930c6fd9dd9bdf31d40593095e959461351d55da1a8e3ad5ed95e0b4b51bea87ca3989ab002ea8ce
PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20251014/cpython-3.11.14%2B20251014-x86_64-unknown-linux-gnu-install_only.tar.gz
PYTHON_SHA256=d0623c777fb89b904b56cd5aba51af29cbb34b1f9d45f0672f90f6dce30fa93e

sudo -n install -d -o hadoop -g hadoop "$RUNTIME"

# Незавершённое скачивание не подменяет готовый архив.
download() {
    local url=$1 destination=$2
    if ! sudo -n test -f "$destination"; then
        sudo -n -u hadoop curl --fail --location --retry 3 --connect-timeout 20 \
            "$url" -o "$destination.part"
        sudo -n -u hadoop mv "$destination.part" "$destination"
    fi
}

download "$SPARK_URL" "$RUNTIME/$SPARK_NAME.tgz"
printf '%s  %s\n' "$SPARK_SHA512" "$RUNTIME/$SPARK_NAME.tgz" \
    | sudo -n -u hadoop sha512sum --check -
if ! sudo -n test -x "$RUNTIME/$SPARK_NAME/bin/spark-submit"; then
    sudo -n -u hadoop tar -xzf "$RUNTIME/$SPARK_NAME.tgz" -C "$RUNTIME"
fi

# Этот же архив Spark распакует в контейнерах YARN.
download "$PYTHON_URL" "$RUNTIME/python.tar.gz"
printf '%s  %s\n' "$PYTHON_SHA256" "$RUNTIME/python.tar.gz" \
    | sudo -n -u hadoop sha256sum --check -
if ! sudo -n test -x "$RUNTIME/python/bin/python3.11"; then
    sudo -n -u hadoop tar -xzf "$RUNTIME/python.tar.gz" -C "$RUNTIME"
fi

sudo -n -u hadoop "$RUNTIME/python/bin/python3.11" --version
sudo -n -u hadoop env JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64 \
    "$RUNTIME/$SPARK_NAME/bin/spark-submit" --version
