#!/usr/bin/env bash
# Запускать на edge после prepare-spark.sh: bash run-spark.sh colours_report.py
set -euo pipefail

cd "$(dirname "$0")"
source ../hw1/cluster.conf
source ../hw3/cluster.conf
[[ $(id -un) == "$SSH_USER" ]] || { echo "Запускайте под $SSH_USER на edge" >&2; exit 1; }

APPLICATION=${1:?Укажите Python-файл для запуска}
test -f "$APPLICATION"
APPLICATION_NAME=$(basename "$APPLICATION")

RUNTIME=/home/hadoop/hw4-spark
SPARK_HOME="$RUNTIME/spark-3.5.9-bin-hadoop3"
HADOOP_CONF_DIR=/home/hadoop/hadoop-3.4.0/etc/hadoop
EDGE_IP=10.33.0.10
METASTORE_LOCAL_PORT=19083

sudo -n test -x "$SPARK_HOME/bin/spark-submit"
sudo -n test -x "$RUNTIME/python/bin/python3.11"
sudo -n test -f "$RUNTIME/python.tar.gz"
sudo -n test -f "$HADOOP_CONF_DIR/yarn-site.xml"

# Metastore слушает localhost на NameNode. Туннель нужен драйверу на edge.
work_dir=$(mktemp -d)
cleanup() {
    if [[ -S "$work_dir/ssh.sock" ]]; then
        ssh -S "$work_dir/ssh.sock" -O exit "$SSH_USER@$NAMENODE_HOST" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
ssh -f -N -M -S "$work_dir/ssh.sock" -i "$SSH_KEY" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$METASTORE_LOCAL_PORT:$METASTORE_HOST:$METASTORE_PORT" \
    "$SSH_USER@$NAMENODE_HOST"

sudo -n install -o hadoop -g hadoop -m 644 "$APPLICATION" "$RUNTIME/$APPLICATION_NAME"

# Рабочий каталог hadoop не зависит от прав доступа к каталогу репозитория team.
sudo -n -H -u hadoop bash -c 'cd "$1" || exit; shift; exec "$@"' bash "$RUNTIME" \
    env JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64 HADOOP_CONF_DIR="$HADOOP_CONF_DIR" \
    PYSPARK_DRIVER_PYTHON="$RUNTIME/python/bin/python3.11" \
    PYSPARK_PYTHON=./python-env/python/bin/python3.11 \
    "$SPARK_HOME/bin/spark-submit" \
    --master yarn --deploy-mode client \
    --driver-memory 1g --num-executors 1 --executor-cores 1 --executor-memory 512m \
    --conf spark.executor.memoryOverhead=384 \
    --conf spark.yarn.am.memory=512m --conf spark.yarn.am.memoryOverhead=384 \
    --conf spark.default.parallelism=1 --conf spark.sql.shuffle.partitions=1 \
    --conf "spark.driver.host=$EDGE_IP" \
    --conf "spark.hadoop.hive.metastore.uris=thrift://127.0.0.1:$METASTORE_LOCAL_PORT" \
    --archives "$RUNTIME/python.tar.gz#python-env" \
    "$RUNTIME/$APPLICATION_NAME" "hdfs://$NAMENODE_IP:9000"
