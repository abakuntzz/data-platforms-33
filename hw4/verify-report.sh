#!/usr/bin/env bash
# Запускать на edge после завершения Spark. Проверяем таблицу через HiveServer2.
set -euo pipefail

cd "$(dirname "$0")"
source ../hw1/cluster.conf
[[ $(id -un) == "$SSH_USER" ]] || { echo "Запускайте под $SSH_USER на edge" >&2; exit 1; }
test -f data/expected-report.tsv

HIVE_DIR=/home/hadoop/apache-hive-4.0.0-alpha-2-bin
JDBC="jdbc:hive2://$NAMENODE_IP:10000"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

run_beeline() {
    ssh -n -T -i "$SSH_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
        -o ConnectTimeout=10 "$SSH_USER@$NAMENODE_HOST" \
        "sudo -n -H -u hadoop bash -lc '
            set -e
            source $HIVE_DIR/conf/hive-env.sh
            export HIVE_CONF_DIR=$HIVE_DIR/conf
            timeout 90 beeline -u $JDBC -n hadoop \
                --silent=true --showHeader=false --outputformat=tsv2 \
                -e \"$1\"
        '"
}

# Сравниваем все строки: лишние строки и дубликаты тоже вызовут ошибку.
tail -n +2 data/expected-report.tsv | LC_ALL=C sort > "$work_dir/expected-rows.tsv"
run_beeline "SELECT colour, max_number, row_count FROM hw4.colours_report;" \
    | LC_ALL=C sort > "$work_dir/actual-rows.tsv"
diff -u "$work_dir/expected-rows.tsv" "$work_dir/actual-rows.tsv"

# Список партиций получаем из тех же цветов, которые есть в эталоне.
tail -n +2 data/expected-report.tsv | cut -f1 | sed 's/^/colour=/' \
    | LC_ALL=C sort > "$work_dir/expected-partitions.txt"
run_beeline "SHOW PARTITIONS hw4.colours_report;" \
    | LC_ALL=C sort > "$work_dir/actual-partitions.txt"
diff -u "$work_dir/expected-partitions.txt" "$work_dir/actual-partitions.txt"

echo "Проверка Hive пройдена: строки и партиции совпадают с эталоном"
