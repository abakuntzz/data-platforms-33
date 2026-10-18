#!/usr/bin/env bash
#
# deploy-hive.sh — установка Apache Hive + HiveServer2 на NameNode
# с проверкой окружения на DataNode и автозагрузкой данных
# в ПАРТИЦИОНИРОВАННУЮ таблицу colours.
#
# Запускать на edge-узле (team-33-en) под пользователем team.

set -euo pipefail

# ─────────────────────────────────────────────────────────
# КОНФИГУРАЦИЯ
# ─────────────────────────────────────────────────────────

HADOOP_DIR=/home/hadoop/hadoop-3.4.0
HIVE_VERSION=4.0.0-alpha-2
HIVE_TARBALL="apache-hive-${HIVE_VERSION}-bin.tar.gz"
HIVE_DIR="/home/hadoop/apache-hive-${HIVE_VERSION}-bin"
HIVE_METASTORE=/home/hadoop/hive-hw03
HS2_LOG=/tmp/hive-hw03-hs2.log
JPS=/usr/lib/jvm/java-11-openjdk-amd64/bin/jps
HIVE_ARCHIVE_URL="https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_TARBALL}"
HIVE_SHA256_URL="${HIVE_ARCHIVE_URL}.sha256"

# Параметры подключения beeline
BEELINE_USER="hadoop"
BEELINE_PASS=""
BEELINE_JDBC="jdbc:hive2://10.33.0.11:10000"

# Данные для загрузки
COLOURS_LOCAL="data/colours.tsv"
COLOURS_HDFS="/input/colours.tsv"
COLOURS_TABLE="test.colours"          # партиционированная таблица
COLOURS_STAGING="test.colours_staging" # промежуточная (не партиционированная)

# ─────────────────────────────────────────────────────────
# ХЕЛПЕРЫ
# ─────────────────────────────────────────────────────────

log()  { echo; echo "=== $*"; }
warn() { echo "  ⚠ $*" >&2; }
die()  { echo "  ✘ $*" >&2; exit 1; }

cd "$(dirname "$0")"

test -f ../hw1/cluster.conf \
    || die "Нет ../hw1/cluster.conf: запускайте из репозитория (hw1 и hw3 рядом)"

# shellcheck disable=SC1091
source ../hw1/cluster.conf
NN="${NAMENODE_HOST:?NAMENODE_HOST не задан}"
NAMENODE_IP="${NAMENODE_IP:?NAMENODE_IP не задан}"

BEELINE_JDBC="jdbc:hive2://${NAMENODE_IP}:10000"

DATANODE_HOSTS=("team-33-00" "team-33-01")

run_on_nn() {
    ssh -n -T -i "$SSH_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "$SSH_USER@$NN" "$@"
}

run_on_nn_stdin() {
    ssh -T -i "$SSH_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "$SSH_USER@$NN" "$@"
}

run_on_nn_background() {
    ssh -f -T -i "$SSH_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "$SSH_USER@$NN" "$@"
}

run_on_dn() {
    local host="$1"; shift
    ssh -n -T -i "$SSH_KEY" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "$SSH_USER@$host" "$@"
}

render_hive_site() {
    sed -e "s/@NAMENODE_IP@/$NAMENODE_IP/g" conf/hive-site.xml
}

# beeline на nn через временный SQL-файл (без /dev/stdin)
run_beeline() {
    local sql_file="$1"
    local remote_sql="/tmp/beeline_hw3_$$.sql"

    scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$sql_file" "$SSH_USER@$NN:$remote_sql" \
        || die "Не удалось скопировать SQL на $NN"

    run_on_nn "sudo -n -u hadoop bash -lc '
        source $HIVE_DIR/conf/hive-env.sh
        beeline -u \"$BEELINE_JDBC\" -n $BEELINE_USER \
            ${BEELINE_PASS:+-p $BEELINE_PASS} \
            --silent=true --showHeader=false --outputformat=tsv2 \
            -f $remote_sql
    '"

    run_on_nn "sudo -n rm -f $remote_sql" || true
}

# ─────────────────────────────────────────────────────────
# 1. ПРОВЕРКИ
# ─────────────────────────────────────────────────────────

log "1. Проверки"

test "$(id -un)" = "$SSH_USER" \
    || die "Запускать на edge под пользователем $SSH_USER (сейчас: $(id -un))"

test -f "$SSH_KEY" || die "Нет $SSH_KEY"
test -f conf/hive-site.xml || die "Нет conf/hive-site.xml"
test -f conf/hive-env.sh   || die "Нет conf/hive-env.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

render_hive_site > "$work_dir/hive-site.xml"

if grep -q '@[A-Z_0-9]*@' "$work_dir/hive-site.xml"; then
    die "В hive-site.xml остались неподставленные метки @VAR@"
fi

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$work_dir/hive-site.xml" \
        || die "hive-site.xml не валиден"
    echo "  ✔ XML валиден (xmllint)"
else
    warn "xmllint не установлен — пропускаю валидацию XML"
fi

run_on_nn "sudo -n test -d $HADOOP_DIR/etc/hadoop" \
    || die "На $NN нет $HADOOP_DIR. Сначала HDFS (ДЗ1)."

run_on_nn "sudo -n -u hadoop $JPS | grep -qw NameNode" \
    || die "На $NN не запущен NameNode"

echo "  ✔ $NN: Hadoop и NameNode на месте"

# ─────────────────────────────────────────────────────────
# 1a. ПРОВЕРКИ ОКРУЖЕНИЯ НА DATANODE
# ─────────────────────────────────────────────────────────

log "1a. Проверки окружения Hadoop на DataNode"

for host in "${DATANODE_HOSTS[@]}"; do
    echo "  → $host"

    if ! run_on_dn "$host" "sudo -n grep -q 'HADOOP_HOME' /home/hadoop/.profile"; then
        die "На $host в /home/hadoop/.profile нет HADOOP_HOME. \
Допишите:
  export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
  export HADOOP_HOME=$HADOOP_DIR
  export HADOOP_CONF_DIR=\\\$HADOOP_HOME/etc/hadoop
  export PATH=\\\$PATH:\\\$JAVA_HOME/bin:\\\$HADOOP_HOME/bin:\\\$HADOOP_HOME/sbin"
    fi

    if ! run_on_dn "$host" "sudo -n -u hadoop bash -lc 'command -v hdfs' >/dev/null 2>&1"; then
        die "На $host команда 'hdfs' не находится в PATH. \
Проверьте: sudo -u hadoop bash -lc 'which hdfs'"
    fi

    if ! run_on_dn "$host" "sudo -n -u hadoop $JPS | grep -qw DataNode"; then
        die "На $host не запущен DataNode. Запустите: ssh $NN '$HADOOP_DIR/sbin/start-dfs.sh'"
    fi

    echo "    ✔ .profile, PATH, DataNode — ок"
done

# ─────────────────────────────────────────────────────────
# 2. УСТАНОВКА HIVE (с пропуском, если уже есть)
# ─────────────────────────────────────────────────────────

log "2. Установка Apache Hive ${HIVE_VERSION} на $NN"

if run_on_nn "sudo -n test -d $HIVE_DIR"; then
    echo "  ✔ Hive уже установлен в $HIVE_DIR — пропускаю скачивание и распаковку."
else
    echo "  Hive не найден — качаю и устанавливаю."

    if [ ! -f "$work_dir/$HIVE_TARBALL" ]; then
        wget --timeout=30 --tries=3 -q -P "$work_dir" "$HIVE_ARCHIVE_URL" \
            || die "Не удалось скачать $HIVE_ARCHIVE_URL"
        wget --timeout=30 --tries=3 -q -P "$work_dir" "$HIVE_SHA256_URL" \
            || die "Не удалось скачать $HIVE_SHA256_URL"
    fi

    (cd "$work_dir" && sha256sum -c "${HIVE_TARBALL}.sha256") \
        || die "Контрольная сумма не совпала"

    run_on_nn "sudo -n install -o hadoop -g hadoop -d $HIVE_METASTORE" \
        || die "Не удалось создать $HIVE_METASTORE"

    scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$work_dir/$HIVE_TARBALL" "$SSH_USER@$NN:/tmp/$HIVE_TARBALL" \
        || die "Не удалось скопировать $HIVE_TARBALL"

    run_on_nn_stdin "bash -s -- '$HIVE_TARBALL' '$HIVE_DIR'" <<'REMOTE'
set -euo pipefail
HIVE_TARBALL="$1"; HIVE_DIR="$2"
sudo -n mv "/tmp/$HIVE_TARBALL" "/home/hadoop/$HIVE_TARBALL"
sudo -n chown hadoop:hadoop "/home/hadoop/$HIVE_TARBALL"
as_hadoop() { sudo -n -H -u hadoop "$@"; }
if as_hadoop test -d "$HIVE_DIR"; then
    echo "  Каталог $HIVE_DIR уже есть — распаковка пропущена."
else
    as_hadoop tar -xzf "/home/hadoop/$HIVE_TARBALL" -C /home/hadoop
    echo "  Hive распакован в $HIVE_DIR."
fi
as_hadoop rm -f "/home/hadoop/$HIVE_TARBALL"
REMOTE
fi

# ─────────────────────────────────────────────────────────
# 3. КОНФИГУРАЦИЯ
# ─────────────────────────────────────────────────────────

log "3. Конфигурация Hive и каталоги HDFS"

run_on_nn_stdin "sudo -n -H -u hadoop tee $HIVE_DIR/conf/hive-site.xml >/dev/null" \
    < "$work_dir/hive-site.xml"

run_on_nn_stdin "sudo -n -H -u hadoop tee $HIVE_DIR/conf/hive-env.sh >/dev/null" \
    < conf/hive-env.sh

run_on_nn_stdin "bash -s -- '$HADOOP_DIR' '$HIVE_DIR' '$HIVE_METASTORE'" <<'REMOTE'
set -euo pipefail
HADOOP_DIR="$1"; HIVE_DIR="$2"; HIVE_METASTORE="$3"
as_hadoop() { sudo -n -H -u hadoop "$@"; }
export HADOOP_HOME="$HADOOP_DIR"
export HIVE_HOME="$HIVE_DIR"
export PATH="$HADOOP_HOME/bin:$HIVE_HOME/bin:$PATH"
as_hadoop "$HADOOP_DIR/bin/hdfs" dfs -mkdir -p /tmp /user/hive/warehouse /input || true
as_hadoop "$HADOOP_DIR/bin/hdfs" dfs -chmod g+w /tmp /user/hive/warehouse || true
if as_hadoop test ! -d "$HIVE_METASTORE/metastore_db"; then
    as_hadoop "$HIVE_DIR/bin/schematool" -dbType derby -initSchema
else
    echo "  Metastore Derby уже инициализирован."
fi
REMOTE

# ─────────────────────────────────────────────────────────
# 4. ЗАПУСК HIVESERVER2
# ─────────────────────────────────────────────────────────

log "4. Запуск HiveServer2"

if run_on_nn "sudo -n ss -tln 2>/dev/null | grep -q ':10000 '"; then
    echo "  ✔ HiveServer2 уже слушает порт 10000."
else
    if run_on_nn "sudo -n -u hadoop pgrep -f 'org.apache.hive.service.server.HiveServer2' >/dev/null"; then
        echo "  Останавливаем прежний HiveServer2..."
        run_on_nn "sudo -n pkill -9 -f 'org.apache.hive.service.server.HiveServer2' || true" || true
        sleep 5
    fi

    echo "  Запускаем HiveServer2..."
    run_on_nn_background \
        "sudo -n -H -u hadoop bash -c 'source $HIVE_DIR/conf/hive-env.sh; setsid nohup hive --service hiveserver2 >> $HS2_LOG 2>&1 < /dev/null &'"

    READY=0
    for i in $(seq 1 60); do
        sleep 3
        if run_on_nn "sudo -n -u hadoop bash -c 'source $HIVE_DIR/conf/hive-env.sh; timeout 15 beeline -u \"$BEELINE_JDBC\" -n $BEELINE_USER ${BEELINE_PASS:+-p $BEELINE_PASS} -e \"show databases;\"' >/dev/null 2>&1"; then
            echo "  ✔ HiveServer2 отвечает на $BEELINE_JDBC."
            READY=1
            break
        fi
    done

    if [ "$READY" -ne 1 ]; then
        echo "  ✘ HiveServer2 не готов за 180 с." >&2
        run_on_nn "sudo -n -u hadoop tail -50 $HS2_LOG" || true
        die "HiveServer2 не запустился"
    fi
fi

# ─────────────────────────────────────────────────────────
# 5. ПОДГОТОВКА ДАННЫХ В HDFS
# ─────────────────────────────────────────────────────────

log "5. Загрузка colours.tsv в HDFS"

# 5.1. Локальный файл (если нет — сгенерировать)
if [ ! -f "$COLOURS_LOCAL" ]; then
    warn "$COLOURS_LOCAL не найден — генерирую пример"
    mkdir -p "$(dirname "$COLOURS_LOCAL")"
    cat > "$COLOURS_LOCAL" <<'EOF'
red     1
green   2
blue    3
yellow  4
black   5
white   6
purple  7
orange  8
pink    9
brown   10
EOF
fi

echo "  Локальный файл: $COLOURS_LOCAL ($(wc -l < "$COLOURS_LOCAL") строк)"

# 5.2. Копируем в HDFS
scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    "$COLOURS_LOCAL" "$SSH_USER@$NN:/tmp/colours.tsv" \
    || die "Не удалось скопировать $COLOURS_LOCAL на $NN"

run_on_nn_stdin "bash -s -- '$HADOOP_DIR' '$COLOURS_HDFS'" <<'REMOTE'
set -euo pipefail
HADOOP_DIR="$1"; HDFS_PATH="$2"
as_hadoop() { sudo -n -H -u hadoop "$@"; }
as_hadoop "$HADOOP_DIR/bin/hdfs" dfs -mkdir -p /input
as_hadoop "$HADOOP_DIR/bin/hdfs" dfs -put -f /tmp/colours.tsv "$HDFS_PATH"
sudo -n rm -f /tmp/colours.tsv
echo "  ✔ Файл в HDFS: $HDFS_PATH"
as_hadoop "$HADOOP_DIR/bin/hdfs" dfs -ls "$HDFS_PATH"
REMOTE

# ─────────────────────────────────────────────────────────
# 6. СОЗДАНИЕ ПАРТИЦИОНИРОВАННОЙ ТАБЛИЦЫ И ЗАГРУЗКА
# ─────────────────────────────────────────────────────────
# Схема:
#   colours (партиционированная по colour)
#       ├── colour=red/     ← number int
#       ├── colour=green/
#       └── ...
#
# Загрузка:
#   1. staging (не партиционированная) ← LOAD DATA из HDFS
#   2. INSERT OVERWRITE ... PARTITION (colour) SELECT ... FROM staging
#      — динамическое партиционирование: Hive сам создаёт партиции
#        по значению colour для каждой строки.
#
# Пересоздание:
#   DROP TABLE IF EXISTS colours / colours_staging
#   → повторный запуск скрипта полностью пересоздаёт таблицу.

log "6. Создание партиционированной таблицы $COLOURS_TABLE и загрузка"

SQL_FILE="$work_dir/load_colours_partitioned.sql"
cat > "$SQL_FILE" <<SQL
-- ─── Пересоздание таблиц ───
DROP TABLE IF EXISTS ${COLOURS_STAGING};
DROP TABLE IF EXISTS ${COLOURS_TABLE};

CREATE DATABASE IF NOT EXISTS test;
USE test;

-- ─── 1. Промежуточная таблица (не партиционированная) ───
CREATE TABLE ${COLOURS_STAGING##*.} (
    colour string,
    number int
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE;

LOAD DATA INPATH '${COLOURS_HDFS}' INTO TABLE ${COLOURS_STAGING##*.};

-- ─── 2. Партиционированная таблица ───
CREATE TABLE ${COLOURS_TABLE##*.} (
    number int
)
PARTITIONED BY (colour string)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE;

-- ─── 3. Динамическое партиционирование ───
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

-- ─── 4. Загрузка в партиции ───
INSERT OVERWRITE TABLE ${COLOURS_TABLE##*.} PARTITION (colour)
SELECT number, colour FROM ${COLOURS_STAGING##*.};

-- ─── 5. Проверка ───
SELECT '=== partitioned table loaded ===' AS status;
SELECT COUNT(*) AS total_rows FROM ${COLOURS_TABLE##*.};
SELECT colour, COUNT(*) AS cnt FROM ${COLOURS_TABLE##*.} GROUP BY colour ORDER BY colour;
SHOW PARTITIONS ${COLOURS_TABLE##*.};
SQL

echo "  SQL-скрипт: $SQL_FILE"
echo "  --- содержимое ---"
sed 's/^/    /' "$SQL_FILE"
echo "  -----------------"

run_beeline "$SQL_FILE" || die "beeline завершился с ошибкой"

echo "  ✔ Партиционированная таблица $COLOURS_TABLE создана и заполнена"

# ─────────────────────────────────────────────────────────
# 7. ПРОВЕРКА ПАРТИЦИЙ
# ─────────────────────────────────────────────────────────

log "7. Проверка партиций и partition pruning"

CHECK_SQL="$work_dir/check_partitions.sql"
cat > "$CHECK_SQL" <<SQL
USE test;
SELECT '--- partitions ---' AS info;
SHOW PARTITIONS ${COLOURS_TABLE##*.};

SELECT '--- rows per partition ---' AS info;
SELECT colour, COUNT(*) AS cnt FROM ${COLOURS_TABLE##*.} GROUP BY colour ORDER BY colour;

SELECT '--- sample: colour=red ---' AS info;
SELECT * FROM ${COLOURS_TABLE##*.} WHERE colour = 'red';

SELECT '--- total rows ---' AS info;
SELECT COUNT(*) AS total FROM ${COLOURS_TABLE##*.};
SQL

run_beeline "$CHECK_SQL" || warn "Не удалось выполнить проверочный запрос"

# ─────────────────────────────────────────────────────────
# 8. EXPLAIN — доказательство partition pruning
# ─────────────────────────────────────────────────────────

log "8. Partition pruning (EXPLAIN)"

EXPLAIN_SQL="$work_dir/explain.sql"
cat > "$EXPLAIN_SQL" <<SQL
USE test;
EXPLAIN SELECT * FROM ${COLOURS_TABLE##*.} WHERE colour = 'red';
SQL

run_beeline "$EXPLAIN_SQL" || warn "EXPLAIN не выполнился"

# ─────────────────────────────────────────────────────────
# ГОТОВО
# ─────────────────────────────────────────────────────────

log "Готово"
echo "  Hive ${HIVE_VERSION} установлен."
echo "  HiveServer2: ${BEELINE_JDBC}"
echo "  Пользователь: ${BEELINE_USER}${BEELINE_PASS:+ (пароль задан)}"
echo ""
echo "  Web UI: http://localhost:10002"
echo "    ssh -L 10002:${NAMENODE_IP}:10002 ${SSH_USER}@${NN}"
echo ""
echo "  Партиционированная таблица: ${COLOURS_TABLE}"
echo "  Партиции: colour=<значение>"
echo "  Данные:   ${COLOURS_HDFS}"
echo ""
echo "  Подключение:"
echo "    beeline -u \"${BEELINE_JDBC}\" -n ${BEELINE_USER}${BEELINE_PASS:+ -p ****}"
echo ""
echo "  Проверка:"
echo "    beeline -u \"${BEELINE_JDBC}\" -n ${BEELINE_USER} -e 'SHOW PARTITIONS test.colours;'"