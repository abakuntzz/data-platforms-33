#!/usr/bin/env bash
# Только локальные заглушки: никакого настоящего SSH, sudo или скачивания.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
WORK_DIR=$TEST_DIR/..
SCRIPT=$WORK_DIR/deploy-hdfs.sh
cd "$WORK_DIR"
bash -n "$SCRIPT"
bash -n "$WORK_DIR/prepare-node.sh"
bash -n cluster.conf
xmllint --noout "$WORK_DIR/hw01-conf/core-site.xml" "$WORK_DIR/hw01-conf/hdfs-site.xml"
test "$(awk 'END {print NR}' "$WORK_DIR/hw01-conf/workers")" = 3
echo 'PASS: синтаксис и конфиги'

test_workspace=$(mktemp -d /tmp/hdfs-hw01-tests.XXXXXX)
trap 'rm -rf "$test_workspace"' EXIT
mkdir "$test_workspace/conf"
export TEST_WORK_DIR=$test_workspace
template_fingerprint=$(sha256sum "$WORK_DIR"/hw01-conf/*)

configure_test() {
    source ./cluster.conf
    export TEST_SSH_USER=$SSH_USER TEST_SSH_KEY=$SSH_KEY
    export TEST_NN_HOST=$NAMENODE_HOST TEST_NN_IP=$NAMENODE_IP
    export TEST_DN0_HOST=$DATANODE_0_HOST TEST_DN0_IP=$DATANODE_0_IP
    export TEST_DN1_HOST=$DATANODE_1_HOST TEST_DN1_IP=$DATANODE_1_IP
    export TEST_HEALTH_URL="http://$NAMENODE_IP:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState"
}
configure_test

check_generated_config() {
    xmllint --noout "$TEST_WORK_DIR/conf/core-site.xml" "$TEST_WORK_DIR/conf/hdfs-site.xml"
    test "$(xmllint --xpath 'string(/configuration/property[name="fs.defaultFS"]/value)' "$TEST_WORK_DIR/conf/core-site.xml")" = "hdfs://$TEST_NN_IP:9000"
    test "$(xmllint --xpath 'string(/configuration/property[name="dfs.namenode.rpc-address"]/value)' "$TEST_WORK_DIR/conf/hdfs-site.xml")" = "$TEST_NN_IP:9000"
    test "$(xmllint --xpath 'string(/configuration/property[name="dfs.namenode.secondary.http-address"]/value)' "$TEST_WORK_DIR/conf/hdfs-site.xml")" = "$TEST_NN_IP:9868"
    cmp "$TEST_WORK_DIR/conf/workers" <(printf '%s\n' "$TEST_NN_IP" "$TEST_DN0_IP" "$TEST_DN1_IP")
    cmp "$TEST_WORK_DIR/known_hosts" <(printf '%s\n' \
        "$TEST_NN_HOST,$TEST_NN_IP ssh-ed25519 FAKE_PUBLIC_KEY" \
        "$TEST_DN0_HOST,$TEST_DN0_IP ssh-ed25519 FAKE_PUBLIC_KEY" \
        "$TEST_DN1_HOST,$TEST_DN1_IP ssh-ed25519 FAKE_PUBLIC_KEY")
}

id() { test "$1" = -un; echo "$TEST_SSH_USER"; }
sudo() {
    case "$*" in
        '-n test ! -e /home/hadoop') test "$TEST_MODE" != existing_home ;;
        '-n test ! -e /tmp/hadoop-hadoop') test "$TEST_MODE" != legacy_data ;;
        '-n test ! -e /home/hadoop/hdfs-hw01/name') test "$TEST_MODE" != existing_metadata ;;
        '-n apt-get install '*) test "$TEST_MODE" != package_error || return 17 ;;
        '-n passwd hadoop') test "$TEST_MODE" != password_error || return 18; echo MOCK_PASSWORD ;;
        '-n cat /home/hadoop/.ssh/id_ed25519.pub') echo 'ssh-ed25519 FAKE_PUBLIC_KEY' ;;
        '-n install -o hadoop -g hadoop -m 600 '*) cp "$9" "$TEST_WORK_DIR/known_hosts" ;;
        '-n cp '*)
            local config_dir
            config_dir=$(dirname "$3")
            cp "$config_dir"/* "$TEST_WORK_DIR/conf/" ;;
        *' hadoop ssh '*)
            case ${12} in
                "$TEST_NN_IP"|"$TEST_DN0_IP"|"$TEST_DN1_IP") return 0 ;;
                *) echo "Неожиданный адрес внутреннего SSH: ${12}" >&2; return 99 ;;
            esac ;;
        *' hadoop scp '*)
            case ${!#} in
                "$TEST_NN_HOST":/home/hadoop/*|"$TEST_DN0_HOST":/home/hadoop/*|"$TEST_DN1_HOST":/home/hadoop/*) return 0 ;;
                *) echo "Неожиданный адрес scp: ${!#}" >&2; return 99 ;;
            esac ;;
        *'namenode -format -nonInteractive') echo MOCK_FORMAT ;;
        *'/sbin/start-dfs.sh') echo MOCK_START ;;
        *'/bin/jps -l')
            echo '101 org.apache.hadoop.hdfs.server.namenode.NameNode'
            if test "$TEST_MODE" != missing_secondary; then
                echo '102 org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode'
            fi
            echo '103 org.apache.hadoop.hdfs.server.datanode.DataNode' ;;
        *'/bin/hdfs dfsadmin -safemode get')
            if test "$TEST_MODE" = safe_mode; then
                echo 'Safe mode is ON'
            else
                echo 'Safe mode is OFF'
            fi ;;
        *) return 0 ;;
    esac
}
ssh() {
    local command target_index target interactive=false
    command=${!#}
    if test "$1" = -t; then
        interactive=true
        shift
    fi
    test "$1" = -i && test "$2" = "$TEST_SSH_KEY" || return 99
    target_index=$(($# - 1))
    target=${!target_index}
    case "$target" in
        "$TEST_SSH_USER@$TEST_NN_HOST"|"$TEST_SSH_USER@$TEST_DN0_HOST"|"$TEST_SSH_USER@$TEST_DN1_HOST") ;;
        *) echo "Неожиданный SSH-пользователь или узел: $target" >&2; return 99 ;;
    esac
    case "$command" in
        'bash -se'|'bash -se -- '*)
            local payload
            payload=$(cat)
            bash -n <<< "$payload"
            bash -c "$command" <<< "$payload" ;;
        'timeout 120 bash -se -- '*)
            local payload
            payload=$(cat)
            bash -n <<< "$payload"
            timeout 2 bash -c "${command#timeout 120 }" <<< "$payload" ;;
        'sudo -n passwd hadoop')
            test "$interactive" = true || { echo 'Для passwd нужен SSH с терминалом' >&2; return 99; }
            test "$TEST_MODE" != remote_password_error || return 18
            sudo -n passwd hadoop ;;
        *'cat /home/hadoop/.ssh/id_ed25519.pub'|*'cat /etc/ssh/ssh_host_ed25519_key.pub') echo 'ssh-ed25519 FAKE_PUBLIC_KEY' ;;
        *'tee '*) cat >/dev/null ;;
        *'ssh-keygen '*) return 0 ;;
        *'sudo -n test ! -e /home/hadoop'*) test "$TEST_MODE" != existing_home ;;
        *'sudo -n -H -u hadoop tar '*) return 0 ;;
        *) echo "Неизвестный mock SSH: $command" >&2; return 98 ;;
    esac
}
wget() {
    if [[ ${!#} == *'/jmx?'* ]]; then
        test "${!#}" = "$TEST_HEALTH_URL" || return 99
        test "$TEST_MODE" != health_request_error || return 8
        local live=3 dead=0
        test "$TEST_MODE" != missing_datanode || live=2
        test "$TEST_MODE" != dead_datanode || dead=1
        printf '{\n  "NumLiveDataNodes": %s,\n  "NumDeadDataNodes": %s,\n  "NumStaleDataNodes": 0,\n  "VolumeFailuresTotal": 0\n}\n' "$live" "$dead"
    fi
    return 0
}
sha512sum() { return 0; }
export -f id sudo ssh wget sha512sum
export TEST_MODE

TEST_MODE=fresh
output=$(bash "$SCRIPT" --init-hdfs)
[[ $output == *MOCK_FORMAT* && $output == *MOCK_START* ]]
[[ $output == *'HDFS готов:'* ]]
check_generated_config
echo 'PASS: последовательность первого запуска (заглушки)'
echo 'PASS: XML, workers и known_hosts соответствуют cluster.conf'
test "$(grep -c '^MOCK_PASSWORD$' <<< "$output")" = 4
echo 'PASS: пароль задаётся на четырёх узлах, удалённый passwd получает терминал'
for TEST_MODE in existing_home legacy_data existing_metadata package_error password_error remote_password_error; do
    if output=$(bash "$SCRIPT" --init-hdfs 2>&1); then
        echo "Неожиданный успех: $TEST_MODE" >&2; exit 1
    fi
    [[ $output != *MOCK_FORMAT* && $output != *MOCK_START* ]]
    echo "PASS: остановка при $TEST_MODE"
done
for TEST_MODE in missing_datanode dead_datanode missing_secondary safe_mode health_request_error; do
    if output=$(bash "$SCRIPT" --init-hdfs 2>&1); then
        echo "Неожиданный успех: $TEST_MODE" >&2; exit 1
    fi
    [[ $output == *MOCK_FORMAT* && $output == *MOCK_START* ]]
    [[ $output == *'Не удалось подтвердить готовность HDFS'* && $output != *'HDFS готов:'* ]]
    echo "PASS: ненулевой код при $TEST_MODE, несмотря на успешный start-dfs.sh"
done
if output=$(bash "$SCRIPT" 2>&1); then echo 'Не запрошен --init-hdfs' >&2; exit 1; fi
[[ $output != *MOCK_FORMAT* && $output != *MOCK_START* ]]
echo 'PASS: явное разрешение на установку'

mkdir "$test_workspace/other-cluster"
cp "$SCRIPT" "$WORK_DIR/prepare-node.sh" "$test_workspace/other-cluster/"
cp -r "$WORK_DIR/hw01-conf" "$test_workspace/other-cluster/"
cat > "$test_workspace/other-cluster/cluster.conf" <<'CONFIG'
EDGE_HOST=198.51.100.42
EDGE_SSH_KEY="$HOME/.ssh/other edge key"
SSH_USER=student
SSH_KEY="$HOME/.ssh/other internal key"
NAMENODE_HOST=course-nn
NAMENODE_IP=10.71.0.11
DATANODE_0_HOST=course-dn0
DATANODE_0_IP=10.71.0.12
DATANODE_1_HOST=course-dn1
DATANODE_1_IP=10.71.0.13
CONFIG
cd "$test_workspace/other-cluster"
configure_test
TEST_MODE=fresh
output=$(bash deploy-hdfs.sh --init-hdfs)
[[ $output == *MOCK_FORMAT* && $output == *MOCK_START* && $output == *'HDFS готов:'* ]]
check_generated_config
echo 'PASS: другая подсеть, имена узлов, SSH-пользователь и путь ключа с пробелами'
test "$(sha256sum "$WORK_DIR"/hw01-conf/*)" = "$template_fingerprint"
echo 'PASS: шаблоны конфигурации не изменились'
echo 'Все проверки пройдены. SSH, sudo и скачивание использовали заглушки.'
