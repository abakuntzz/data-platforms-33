#!/usr/bin/env bash
set -euo pipefail

HADOOP_DIR=/home/hadoop/hadoop-3.4.0
CONF_DIR=$HADOOP_DIR/etc/hadoop
YARN_DIRS="/home/hadoop/yarn-hw02/local /home/hadoop/yarn-hw02/logs"
JPS=/usr/lib/jvm/java-11-openjdk-amd64/bin/jps
FILES="yarn-site.xml mapred-site.xml"

cd "$(dirname "$0")"
test -f ../hw1/cluster.conf || { echo "Нет ../hw1/cluster.conf: запускайте из репозитория (hw1 и hw2 рядом)" >&2; exit 1; }
source ../hw1/cluster.conf
NN=$NAMENODE_HOST
NODES="edge $NAMENODE_HOST $DATANODE_0_HOST $DATANODE_1_HOST"

log() { echo; echo "=== $*"; }

run_on() {
    local node=$1; shift
    if [ "$node" = edge ]; then
        bash -c "$*"
    else
        ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
            -o ConnectTimeout=10 "$SSH_USER@$node" "$*"
    fi
}

render() {
    sed -e "s/@NAMENODE_IP@/$NAMENODE_IP/g" \
        -e "s/@DATANODE_0_IP@/$DATANODE_0_IP/g" \
        -e "s/@DATANODE_1_IP@/$DATANODE_1_IP/g" "$1"
}

# Проверки
log "1. Проверки"
test "$(id -un)" = "$SSH_USER" || { echo "Запускать под пользователем $SSH_USER" >&2; exit 1; }
test -f "$SSH_KEY" || { echo "Нет $SSH_KEY: запускайте на edge" >&2; exit 1; }
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
for f in $FILES; do
    test -f "conf/$f" || { echo "Нет файла conf/$f рядом со скриптом" >&2; exit 1; }
    render "conf/$f" > "$work_dir/$f"
    ! grep -q '@[A-Z_0-9]*@' "$work_dir/$f" || { echo "В conf/$f остались неподставленные метки" >&2; exit 1; }
done
for node in $NODES; do
    run_on "$node" "sudo -n test -d $CONF_DIR" \
        || { echo "$node: нет $CONF_DIR или нет доступа" >&2; exit 1; }
    echo "$node: доступен, Hadoop на месте"
done
run_on "$NN" "sudo -n -u hadoop $JPS | grep -qw NameNode" \
    || { echo "На $NN не запущен NameNode. Сначала поднимите HDFS (ДЗ1)." >&2; exit 1; }
echo "$NN: NameNode работает"

# Заменяем 127.0.1.1 на IP узла
for pair in "$NAMENODE_HOST=$NAMENODE_IP" "$DATANODE_0_HOST=$DATANODE_0_IP" "$DATANODE_1_HOST=$DATANODE_1_IP"; do
    node=${pair%=*}; ip=${pair#*=}
    log "2. /etc/hosts на $node"
    run_on "$node" "sudo -n test -e /etc/hosts.bak-hw2 || sudo -n cp -p /etc/hosts /etc/hosts.bak-hw2"
    run_on "$node" "sudo -n sed -i -E '/[[:space:]]$node([[:space:]]|\$)/ s/^127\.0\.1\.1([[:space:]])/$ip\1/' /etc/hosts"
    # Проверка: имя машины (и полное, и короткое) должно указывать на внутренний IP.
    run_on "$node" "getent ahostsv4 \$(hostname -f) | head -1; test \"\$(getent ahostsv4 \$(hostname -f) | awk 'NR==1{print \$1}')\" = $ip" \
        || { echo "$node: имя узла по-прежнему не указывает на $ip, см. /etc/hosts" >&2; exit 1; }
    echo "/etc/hosts исправлен (бэкап: /etc/hosts.bak-hw2)"
done

# Настройка конфигов
for node in $NODES; do
    log "3. Конфиги на $node"
    for f in $FILES; do
        run_on "$node" "sudo -n test -e $CONF_DIR/$f.bak-hw2 || sudo -n -u hadoop cp -p $CONF_DIR/$f $CONF_DIR/$f.bak-hw2"
        run_on "$node" "sudo -n -u hadoop tee $CONF_DIR/$f >/dev/null" < "$work_dir/$f"
        echo "$f обновлён (бэкап: $f.bak-hw2)"
    done
    run_on "$node" "sudo -n -u hadoop mkdir -p $YARN_DIRS && sudo -n -u hadoop chmod 750 /home/hadoop/yarn-hw02"
    echo "Рабочие папки YARN: /home/hadoop/yarn-hw02"
done

# Запуск YARN и History Server на NameNode
log "4. Запуск YARN на $NN (пользователь hadoop)"
run_on "$NN" "bash -se" <<REMOTE
set -euo pipefail
as_hadoop() { sudo -n -H -u hadoop "\$@"; }
as_hadoop $HADOOP_DIR/bin/mapred --daemon stop historyserver || true
as_hadoop $HADOOP_DIR/sbin/stop-yarn.sh || true
as_hadoop $HADOOP_DIR/sbin/start-yarn.sh
as_hadoop $HADOOP_DIR/bin/mapred --daemon start historyserver
for i in \$(seq 1 30); do
    n=\$(as_hadoop $HADOOP_DIR/bin/yarn node -list 2>/dev/null | grep -c RUNNING || true)
    [ "\$n" -ge 3 ] && break
    sleep 3
done
echo
as_hadoop $JPS
echo
as_hadoop $HADOOP_DIR/bin/yarn node -list
[ "\$n" -ge 3 ] || { echo "Зарегистрировалось NodeManager: \$n из 3. Смотрите логи в $HADOOP_DIR/logs" >&2; exit 1; }
REMOTE

for ((attempt = 0; attempt < 30; attempt++)); do
    history_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$NAMENODE_IP:19888/ws/v1/history/info" || true)
    [ "$history_code" = 200 ] && break
    sleep 3
done
[ "$history_code" = 200 ] || { echo "History Server не готов: HTTP $history_code. Смотрите логи в $HADOOP_DIR/logs" >&2; exit 1; }

log "Готово: YARN запущен, 3 NodeManager в строю, History Server готов."
echo "Интерфейсы внутри кластера: ResourceManager http://$NAMENODE_IP:8088, History http://$NAMENODE_IP:19888"
