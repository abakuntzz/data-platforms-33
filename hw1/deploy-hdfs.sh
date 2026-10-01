#!/usr/bin/env bash
set -euo pipefail
test "${1:-}" = --init-hdfs || { echo 'На edge: bash deploy-hdfs.sh --init-hdfs (только чистые ВМ)' >&2; exit 1; }
test "$(id -un)" = team
cd "$(dirname "$0")"

ssh_team() {
    local node=$1
    shift
    ssh -i "$HOME/.ssh/team_internal" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=10 "team@$node" "$@"
}

# 1. Подготовка четырёх ВМ.
sudo -n test ! -e /home/hadoop
sudo -n test ! -e /tmp/hadoop-hadoop
for node in team-33-nn team-33-00 team-33-01; do
    ssh_team "$node" 'sudo -n test ! -e /home/hadoop && sudo -n test ! -e /tmp/hadoop-hadoop'
done
bash prepare-node.sh
echo 'Задайте надёжный пароль пользователя hadoop на edge.'
sudo -n passwd hadoop
for node in team-33-nn team-33-00 team-33-01; do
    ssh_team "$node" 'bash -se' < prepare-node.sh
    echo "Задайте пароль пользователя hadoop на $node."
    ssh -t -i "$HOME/.ssh/team_internal" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=10 "team@$node" 'sudo -n passwd hadoop'
done

# 2. SSH-ключи, как в инструкции. Передаём только публичные части.
work_dir=$(mktemp -d /tmp/hdfs-hw01.XXXXXX)
sudo -n -H -u hadoop ssh-keygen -q -t ed25519 -f /home/hadoop/.ssh/id_ed25519 -N ''
ssh_team team-33-nn "sudo -n -H -u hadoop ssh-keygen -q -t ed25519 -f /home/hadoop/.ssh/id_ed25519 -N ''"
sudo -n cat /home/hadoop/.ssh/id_ed25519.pub > "$work_dir/authorized_keys"
ssh_team team-33-nn 'sudo -n cat /home/hadoop/.ssh/id_ed25519.pub' >> "$work_dir/authorized_keys"
for node in team-33-nn team-33-00 team-33-01; do
    ssh_team "$node" '
        set -e
        sudo -n tee -a /home/hadoop/.ssh/authorized_keys >/dev/null
        sudo -n chown hadoop:hadoop /home/hadoop/.ssh/authorized_keys
        sudo -n chmod 600 /home/hadoop/.ssh/authorized_keys
    ' < "$work_dir/authorized_keys"
done
ssh_team team-33-nn 'cat /etc/ssh/ssh_host_ed25519_key.pub' | sed 's/^/team-33-nn,10.33.0.11 /' > "$work_dir/known_hosts"
ssh_team team-33-00 'cat /etc/ssh/ssh_host_ed25519_key.pub' | sed 's/^/team-33-00,10.33.0.12 /' >> "$work_dir/known_hosts"
ssh_team team-33-01 'cat /etc/ssh/ssh_host_ed25519_key.pub' | sed 's/^/team-33-01,10.33.0.13 /' >> "$work_dir/known_hosts"
sudo -n install -o hadoop -g hadoop -m 600 "$work_dir/known_hosts" /home/hadoop/.ssh/known_hosts
ssh_team team-33-nn '
    set -e
    sudo -n tee /home/hadoop/.ssh/known_hosts >/dev/null
    sudo -n chown hadoop:hadoop /home/hadoop/.ssh/known_hosts
    sudo -n chmod 600 /home/hadoop/.ssh/known_hosts
' < "$work_dir/known_hosts"
ssh_team team-33-nn 'bash -se' <<'CHECK_SSH'
for node in 10.33.0.11 10.33.0.12 10.33.0.13; do
    sudo -n -H -u hadoop ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$node" 'test "$(id -un)" = hadoop'
done
CHECK_SSH

# 3. Скачивание, распаковка и копирование готовых конфигов.
wget --timeout=30 --tries=3 -P "$work_dir" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz
wget --timeout=30 --tries=3 -P "$work_dir" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz.sha512
(cd "$work_dir" && sha512sum -c hadoop-3.4.0.tar.gz.sha512)
sudo -n install -o hadoop -g hadoop -m 644 "$work_dir/hadoop-3.4.0.tar.gz" /home/hadoop/hadoop-3.4.0.tar.gz
sudo -n -H -u hadoop tar -xzf /home/hadoop/hadoop-3.4.0.tar.gz -C /home/hadoop
sudo -n cp hw01-conf/* /home/hadoop/hadoop-3.4.0/etc/hadoop/
for node in team-33-nn team-33-00 team-33-01; do
    sudo -n -H -u hadoop scp -o BatchMode=yes -o StrictHostKeyChecking=yes /home/hadoop/hadoop-3.4.0.tar.gz "$node:/home/hadoop/"
    ssh_team "$node" 'sudo -n -H -u hadoop tar -xzf /home/hadoop/hadoop-3.4.0.tar.gz -C /home/hadoop'
    sudo -n -H -u hadoop scp -o BatchMode=yes -o StrictHostKeyChecking=yes /home/hadoop/hadoop-3.4.0/etc/hadoop/{core-site.xml,hdfs-site.xml,workers,hadoop-env.sh} "$node:/home/hadoop/hadoop-3.4.0/etc/hadoop/"
done

# 4. Однократное форматирование и штатный запуск.
ssh_team team-33-nn 'bash -se' <<'START_HDFS'
sudo -n test ! -e /home/hadoop/hdfs-hw01/name
sudo -n -H -u hadoop /home/hadoop/hadoop-3.4.0/bin/hdfs namenode -format -nonInteractive
sudo -n -H -u hadoop /home/hadoop/hadoop-3.4.0/sbin/start-dfs.sh
START_HDFS
echo 'Команды запуска выполнены. Теперь проверить три live DataNode в UI по README.'
