#!/usr/bin/env bash
set -euo pipefail
test "${1:-}" = --init-hdfs || { echo 'На edge: bash deploy-hdfs.sh --init-hdfs (только чистые ВМ)' >&2; exit 1; }
cd "$(dirname "$0")"
source ./cluster.conf
test "$(id -un)" = "$SSH_USER"
nodes=("$NAMENODE_HOST" "$DATANODE_0_HOST" "$DATANODE_1_HOST")
node_ips=("$NAMENODE_IP" "$DATANODE_0_IP" "$DATANODE_1_IP")
ssh_options=(-i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=10)

ssh_node() {
    local node=$1
    shift
    ssh "${ssh_options[@]}" "$SSH_USER@$node" "$@"
}

# 1. Подготовка четырёх ВМ.
sudo -n test ! -e /home/hadoop
sudo -n test ! -e /tmp/hadoop-hadoop
for node in "${nodes[@]}"; do
    ssh_node "$node" 'sudo -n test ! -e /home/hadoop && sudo -n test ! -e /tmp/hadoop-hadoop'
done
bash prepare-node.sh
echo 'Задайте надёжный пароль пользователя hadoop на edge.'
sudo -n passwd hadoop
for node in "${nodes[@]}"; do
    ssh_node "$node" 'bash -se' < prepare-node.sh
    echo "Задайте пароль пользователя hadoop на $node."
    ssh -t "${ssh_options[@]}" "$SSH_USER@$node" 'sudo -n passwd hadoop'
done

# 2. SSH-ключи, как в инструкции. Передаём только публичные части.
work_dir=$(mktemp -d /tmp/hdfs-hw01.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
sudo -n -H -u hadoop ssh-keygen -q -t ed25519 -f /home/hadoop/.ssh/id_ed25519 -N ''
ssh_node "$NAMENODE_HOST" "sudo -n -H -u hadoop ssh-keygen -q -t ed25519 -f /home/hadoop/.ssh/id_ed25519 -N ''"
sudo -n cat /home/hadoop/.ssh/id_ed25519.pub > "$work_dir/authorized_keys"
ssh_node "$NAMENODE_HOST" 'sudo -n cat /home/hadoop/.ssh/id_ed25519.pub' >> "$work_dir/authorized_keys"
for node in "${nodes[@]}"; do
    ssh_node "$node" '
        set -e
        sudo -n tee -a /home/hadoop/.ssh/authorized_keys >/dev/null
        sudo -n chown hadoop:hadoop /home/hadoop/.ssh/authorized_keys
        sudo -n chmod 600 /home/hadoop/.ssh/authorized_keys
    ' < "$work_dir/authorized_keys"
done
: > "$work_dir/known_hosts"
for index in "${!nodes[@]}"; do
    ssh_node "${nodes[$index]}" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | sed "s/^/${nodes[$index]},${node_ips[$index]} /" >> "$work_dir/known_hosts"
done
sudo -n install -o hadoop -g hadoop -m 600 "$work_dir/known_hosts" /home/hadoop/.ssh/known_hosts
ssh_node "$NAMENODE_HOST" '
    set -e
    sudo -n tee /home/hadoop/.ssh/known_hosts >/dev/null
    sudo -n chown hadoop:hadoop /home/hadoop/.ssh/known_hosts
    sudo -n chmod 600 /home/hadoop/.ssh/known_hosts
' < "$work_dir/known_hosts"
printf -v check_ssh_command 'bash -se -- %q %q %q' "${node_ips[@]}"
ssh_node "$NAMENODE_HOST" "$check_ssh_command" <<'CHECK_SSH'
for node in "$@"; do
    sudo -n -H -u hadoop ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$node" 'test "$(id -un)" = hadoop'
done
CHECK_SSH

# 3. Скачивание, распаковка и копирование готовых конфигов.
mkdir "$work_dir/conf"
for conf_file in core-site.xml hdfs-site.xml workers; do
    sed -e "s/@NAMENODE_IP@/$NAMENODE_IP/g" \
        -e "s/@DATANODE_0_IP@/$DATANODE_0_IP/g" \
        -e "s/@DATANODE_1_IP@/$DATANODE_1_IP/g" \
        "hw01-conf/$conf_file" > "$work_dir/conf/$conf_file"
done
cp hw01-conf/hadoop-env.sh "$work_dir/conf/"
wget --timeout=30 --tries=3 -P "$work_dir" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz
wget --timeout=30 --tries=3 -P "$work_dir" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz.sha512
(cd "$work_dir" && sha512sum -c hadoop-3.4.0.tar.gz.sha512)
sudo -n install -o hadoop -g hadoop -m 644 "$work_dir/hadoop-3.4.0.tar.gz" /home/hadoop/hadoop-3.4.0.tar.gz
sudo -n -H -u hadoop tar -xzf /home/hadoop/hadoop-3.4.0.tar.gz -C /home/hadoop
sudo -n cp "$work_dir"/conf/* /home/hadoop/hadoop-3.4.0/etc/hadoop/
for node in "${nodes[@]}"; do
    sudo -n -H -u hadoop scp -o BatchMode=yes -o StrictHostKeyChecking=yes /home/hadoop/hadoop-3.4.0.tar.gz "$node:/home/hadoop/"
    ssh_node "$node" 'sudo -n -H -u hadoop tar -xzf /home/hadoop/hadoop-3.4.0.tar.gz -C /home/hadoop'
    sudo -n -H -u hadoop scp -o BatchMode=yes -o StrictHostKeyChecking=yes /home/hadoop/hadoop-3.4.0/etc/hadoop/{core-site.xml,hdfs-site.xml,workers,hadoop-env.sh} "$node:/home/hadoop/hadoop-3.4.0/etc/hadoop/"
done

# 4. Однократное форматирование и штатный запуск.
ssh_node "$NAMENODE_HOST" 'bash -se' <<'START_HDFS'
sudo -n test ! -e /home/hadoop/hdfs-hw01/name
sudo -n -H -u hadoop /home/hadoop/hadoop-3.4.0/bin/hdfs namenode -format -nonInteractive
sudo -n -H -u hadoop /home/hadoop/hadoop-3.4.0/sbin/start-dfs.sh
START_HDFS
printf -v check_hdfs_command 'timeout 120 bash -se -- %q' "http://$NAMENODE_IP:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState"
if ssh_node "$NAMENODE_HOST" "$check_hdfs_command" <<'CHECK_HDFS'
set -euo pipefail
while true; do
    if processes=$(sudo -n -H -u hadoop /usr/lib/jvm/java-11-openjdk-amd64/bin/jps -l) &&
        grep -q ' org.apache.hadoop.hdfs.server.namenode.NameNode$' <<< "$processes" &&
        grep -q ' org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode$' <<< "$processes" &&
        grep -q ' org.apache.hadoop.hdfs.server.datanode.DataNode$' <<< "$processes" &&
        health=$(wget --timeout=5 --tries=1 -qO- "$1") &&
        grep -Eq '"NumLiveDataNodes"[[:space:]]*:[[:space:]]*3([,[:space:]]|$)' <<< "$health" &&
        grep -Eq '"NumDeadDataNodes"[[:space:]]*:[[:space:]]*0([,[:space:]]|$)' <<< "$health" &&
        grep -Eq '"NumStaleDataNodes"[[:space:]]*:[[:space:]]*0([,[:space:]]|$)' <<< "$health" &&
        grep -Eq '"VolumeFailuresTotal"[[:space:]]*:[[:space:]]*0([,[:space:]]|$)' <<< "$health" &&
        safemode=$(sudo -n -H -u hadoop timeout 10 /home/hadoop/hadoop-3.4.0/bin/hdfs dfsadmin -safemode get) &&
        test "$safemode" = 'Safe mode is OFF'; then
        exit 0
    fi
    sleep 3
done
CHECK_HDFS
then
    echo 'HDFS готов: NN, SNN и три live DataNode, Safe Mode выключен. Проверить UI по README.'
else
    echo 'Не удалось подтвердить готовность HDFS за 120 секунд. Проверить процессы, SSH и логи по README; не повторять --init-hdfs.' >&2
    exit 1
fi
