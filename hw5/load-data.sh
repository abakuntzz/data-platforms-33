#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./hw5-env.sh

INPUT_DIR=$HDFS_URL/user/hadoop/hw05/input

hdfs dfs -mkdir -p "$INPUT_DIR"
hdfs dfs -put -f data/colours.tsv "$INPUT_DIR/colours.tsv"

hdfs dfs -ls "$INPUT_DIR"
echo "Строк в файле (с заголовком): $(hdfs dfs -cat "$INPUT_DIR/colours.tsv" | wc -l)"
