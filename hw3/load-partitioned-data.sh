#!/usr/bin/env bash
set -euo pipefail

HADOOP_DIR=/home/hadoop/hadoop-3.4.0
HIVE_VERSION=4.0.0-alpha-2
HIVE_DIR=/home/hadoop/apache-hive-${HIVE_VERSION}-bin
HDFS_INPUT=/input/hw03/colours

cd "$(dirname "$0")"
test -f ../hw1/cluster.conf || { echo "Нет ../hw1/cluster.conf: запускайте из репозитория (hw1 и hw3 рядом)" >&2; exit 1; }
source ../hw1/cluster.conf
NN=$NAMENODE_HOST

log() { echo; echo "=== $*"; }

run_on_nn() {
    ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "$SSH_USER@$NN" "$@"
}

test "$(id -un)" = "$SSH_USER" || { echo "Запускать на edge под пользователем $SSH_USER" >&2; exit 1; }
test -f "$SSH_KEY" || { echo "Нет $SSH_KEY: запускайте на edge" >&2; exit 1; }
test -f sql/partitioned-colours.hql || { echo "Нет sql/partitioned-colours.hql" >&2; exit 1; }
for part in red blue; do
    test -f "data/$part/data.tsv" || { echo "Нет data/$part/data.tsv" >&2; exit 1; }
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/red" "$work_dir/blue"
cp data/red/data.tsv "$work_dir/red/"
cp data/blue/data.tsv "$work_dir/blue/"
cp sql/partitioned-colours.hql "$work_dir/"

log "1. Проверка HiveServer2 на $NN"
run_on_nn "sudo -n test -d $HIVE_DIR" \
    || { echo "Hive не установлен. Сначала выполните bash deploy-hive.sh" >&2; exit 1; }
run_on_nn "bash -se" <<'CHECK'
set -euo pipefail
sudo -n -H -u hadoop bash -c '
    source /home/hadoop/apache-hive-4.0.0-alpha-2-bin/conf/hive-env.sh
    beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "show databases;" >/dev/null
'
CHECK

log "2. Загрузка файлов в HDFS ($HDFS_INPUT)"
run_on_nn "sudo -n -H -u hadoop rm -rf $HDFS_INPUT/{red,blue} || true"
for part in red blue; do
    scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$work_dir/$part/data.tsv" "$SSH_USER@$NN:/tmp/hw03-$part-data.tsv"
    run_on_nn "bash -se" <<REMOTE
set -euo pipefail
sudo -n -H -u hadoop bash -c '
    hdfs dfs -mkdir -p $HDFS_INPUT/$part
    hdfs dfs -put -f /tmp/hw03-$part-data.tsv $HDFS_INPUT/$part/data.tsv
'
rm -f /tmp/hw03-$part-data.tsv
REMOTE
done

log "3. Создание партиционированной таблицы и LOAD DATA через Beeline"
run_on_nn "sudo -n -H -u hadoop tee /tmp/hw03-partitioned-colours.hql >/dev/null" < "$work_dir/partitioned-colours.hql"
run_on_nn "bash -se" <<REMOTE
set -euo pipefail
sudo -n -H -u hadoop bash -c '
    source $HIVE_DIR/conf/hive-env.sh
    beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -f /tmp/hw03-partitioned-colours.hql
    beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "SHOW PARTITIONS test.colours;"
    beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "SELECT colour, number FROM test.colours ORDER BY colour, number;"
'
sudo -n -H -u hadoop rm -f /tmp/hw03-partitioned-colours.hql
REMOTE

log "Готово: данные загружены в партиционированную таблицу test.colours"
echo "Проверка с edge: beeline -u jdbc:hive2://${NAMENODE_IP}:10000 -n hadoop -e 'SELECT * FROM test.colours;'"
