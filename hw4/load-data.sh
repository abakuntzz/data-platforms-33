#!/usr/bin/env bash
# Запускать на edge под team. Загружаем только входной файл ДЗ4.
set -euo pipefail

cd "$(dirname "$0")"
source ../hw1/cluster.conf
[[ $(id -un) == "$SSH_USER" ]] || { echo "Запускайте под $SSH_USER на edge" >&2; exit 1; }

HDFS=/home/hadoop/hadoop-3.4.0/bin/hdfs
INPUT_DIR="hdfs://$NAMENODE_IP:9000/user/hadoop/hw04/input"
INPUT="$INPUT_DIR/colours.tsv"

test -f data/colours.tsv
sudo -n test -x "$HDFS"
sudo -n -u hadoop "$HDFS" dfs -mkdir -p "$INPUT_DIR"

# Через stdin: пользователю hadoop не нужны права на каталог репозитория team.
sudo -n -u hadoop "$HDFS" dfs -put -f - "$INPUT" < data/colours.tsv

# Читаем загруженный файл обратно и сравниваем с оригиналом.
sudo -n -u hadoop "$HDFS" dfs -cat "$INPUT" | cmp data/colours.tsv -
echo "Файл загружен и проверен: $INPUT"
