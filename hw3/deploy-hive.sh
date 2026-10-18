#!/usr/bin/env bash
set -euo pipefail

HADOOP_DIR=/home/hadoop/hadoop-3.4.0
HIVE_VERSION=4.0.0-alpha-2
HIVE_TARBALL=apache-hive-${HIVE_VERSION}-bin.tar.gz
HIVE_DIR=/home/hadoop/apache-hive-${HIVE_VERSION}-bin
HIVE_METASTORE=/home/hadoop/hive-hw03
HS2_LOG=/tmp/hive-hw03-hs2.log
JPS=/usr/lib/jvm/java-11-openjdk-amd64/bin/jps
HIVE_ARCHIVE_URL="https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_TARBALL}"
HIVE_SHA256_URL="${HIVE_ARCHIVE_URL}.sha256"

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

render_hive_site() {
    sed -e "s/@NAMENODE_IP@/$NAMENODE_IP/g" conf/hive-site.xml
}

# --- проверки ---
log "1. Проверки"
test "$(id -un)" = "$SSH_USER" || { echo "Запускать на edge под пользователем $SSH_USER" >&2; exit 1; }
test -f "$SSH_KEY" || { echo "Нет $SSH_KEY: запускайте на edge" >&2; exit 1; }
test -f conf/hive-site.xml && test -f conf/hive-env.sh \
    || { echo "Нет conf/hive-site.xml или conf/hive-env.sh рядом со скриптом" >&2; exit 1; }
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
render_hive_site > "$work_dir/hive-site.xml"
! grep -q '@[A-Z_0-9]*@' "$work_dir/hive-site.xml" \
    || { echo "В hive-site.xml остались неподставленные метки" >&2; exit 1; }
xmllint --noout "$work_dir/hive-site.xml"

run_on_nn "sudo -n test -d $HADOOP_DIR/etc/hadoop" \
    || { echo "На $NN нет $HADOOP_DIR. Сначала поднимите HDFS (ДЗ1)." >&2; exit 1; }
run_on_nn "sudo -n -u hadoop $JPS | grep -qw NameNode" \
    || { echo "На $NN не запущен NameNode. Сначала поднимите HDFS (ДЗ1)." >&2; exit 1; }
echo "$NN: Hadoop и NameNode на месте"

# --- дистрибутив Hive на NameNode ---
log "2. Установка Apache Hive ${HIVE_VERSION} на $NN"
wget --timeout=30 --tries=3 -P "$work_dir" "$HIVE_ARCHIVE_URL"
wget --timeout=30 --tries=3 -P "$work_dir" "$HIVE_SHA256_URL"
(cd "$work_dir" && sha256sum -c "${HIVE_TARBALL}.sha256")
run_on_nn "sudo -n install -o hadoop -g hadoop -d $HIVE_METASTORE"
scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    "$work_dir/$HIVE_TARBALL" "$SSH_USER@$NN:/tmp/$HIVE_TARBALL"
run_on_nn "bash -se" <<REMOTE
set -euo pipefail
as_hadoop() { sudo -n -H -u hadoop "\$@"; }
as_hadoop mv /tmp/$HIVE_TARBALL /home/hadoop/$HIVE_TARBALL
if as_hadoop test -d $HIVE_DIR; then
    echo "Каталог $HIVE_DIR уже есть — повторная распаковка не выполняется."
else
    as_hadoop tar -xzf /home/hadoop/$HIVE_TARBALL -C /home/hadoop
fi
as_hadoop rm -f /home/hadoop/$HIVE_TARBALL
REMOTE

log "3. Конфигурация Hive и каталоги HDFS"
run_on_nn "sudo -n -H -u hadoop tee $HIVE_DIR/conf/hive-site.xml >/dev/null" < "$work_dir/hive-site.xml"
run_on_nn "sudo -n -H -u hadoop tee $HIVE_DIR/conf/hive-env.sh >/dev/null" < conf/hive-env.sh
run_on_nn "bash -se" <<REMOTE
set -euo pipefail
as_hadoop() { sudo -n -H -u hadoop "\$@"; }
export HADOOP_HOME=$HADOOP_DIR HIVE_HOME=$HIVE_DIR
export PATH="\$HADOOP_HOME/bin:\$HIVE_HOME/bin:\$PATH"
as_hadoop hdfs dfs -mkdir -p /tmp /user/hive/warehouse /input/hw03 || true
as_hadoop hdfs dfs -chmod g+w /tmp /user/hive/warehouse || true
if as_hadoop test ! -d $HIVE_METASTORE/metastore_db; then
    as_hadoop $HIVE_DIR/bin/schematool -dbType derby -initSchema
else
    echo "Metastore Derby уже инициализирован ($HIVE_METASTORE/metastore_db)."
fi
REMOTE

log "4. Запуск HiveServer2 (не embedded CLI)"
run_on_nn "bash -se" <<REMOTE
set -euo pipefail
as_hadoop() { sudo -n -H -u hadoop "\$@"; }
if pgrep -u hadoop -f 'org.apache.hive.service.server.HiveServer2' >/dev/null 2>&1; then
    echo "Останавливаем прежний HiveServer2..."
    as_hadoop pkill -f 'org.apache.hive.service.server.HiveServer2' || true
    sleep 3
fi
as_hadoop bash -c '
    set -euo pipefail
    source $HIVE_DIR/conf/hive-env.sh
    nohup hive --service hiveserver2 >> $HS2_LOG 2>&1 &
'
for i in \$(seq 1 60); do
    if as_hadoop bash -c '
        source $HIVE_DIR/conf/hive-env.sh
        beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "show databases;" >/dev/null 2>&1
    '; then
        echo "HiveServer2 отвечает на порту 10000."
        exit 0
    fi
    sleep 3
done
echo "HiveServer2 не готов за 180 с. Смотрите $HS2_LOG на $NN." >&2
as_hadoop tail -30 $HS2_LOG || true
exit 1
REMOTE

log "Готово: Hive ${HIVE_VERSION} установлен, HiveServer2 слушает jdbc:hive2://${NAMENODE_IP}:10000"
echo "Загрузите данные в партиционированную таблицу: bash load-partitioned-data.sh"
echo "Клиенты подключаются через Beeline к HiveServer2, не через embedded hive CLI."
