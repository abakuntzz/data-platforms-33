#!/usr/bin/env bash
# Только локальные заглушки: никакого настоящего SSH, sudo, curl или nginx.
set -euo pipefail
trap 'echo "FAIL: строка $LINENO" >&2' ERR
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
WORK_DIR=$TEST_DIR/..
cd "$WORK_DIR"
bash -n deploy-yarn.sh
bash -n publish-web.sh
bash -n ../hw1/cluster.conf
xmllint --noout conf/yarn-site.xml conf/mapred-site.xml
test "$(grep -c 'proxy_pass http://@' conf/nginx-hadoop.conf)" = 7
echo 'PASS: синтаксис и шаблоны'

test_workspace=$(mktemp -d /tmp/yarn-hw02-tests.XXXXXX)
trap 'rm -rf "$test_workspace"' EXIT
export TEST_WORK_DIR=$test_workspace
template_fingerprint=$(sha256sum conf/*)

configure_test() {
    export HOME=$test_workspace/home
    source "$1"
    mkdir -p "$(dirname "$SSH_KEY")"
    touch "$SSH_KEY"
    export TEST_SSH_USER=$SSH_USER TEST_SSH_KEY=$SSH_KEY TEST_EDGE_HOST=$EDGE_HOST
    export TEST_NN_HOST=$NAMENODE_HOST TEST_NN_IP=$NAMENODE_IP
    export TEST_DN0_HOST=$DATANODE_0_HOST TEST_DN0_IP=$DATANODE_0_IP
    export TEST_DN1_HOST=$DATANODE_1_HOST TEST_DN1_IP=$DATANODE_1_IP
}
configure_test ../hw1/cluster.conf

reset_state() {
    rm -rf "$TEST_WORK_DIR/nodes" "$TEST_WORK_DIR/calls" "$TEST_WORK_DIR/nginx-site"
    mkdir -p "$TEST_WORK_DIR/nodes"
    : > "$TEST_WORK_DIR/calls"
    export TEST_CURRENT_NODE=edge
}

xml_value() { xmllint --xpath "string(/configuration/property[name=\"$2\"]/value)" "$1"; }

check_yarn_configs() {
    local node dir
    for node in edge "$TEST_NN_HOST" "$TEST_DN0_HOST" "$TEST_DN1_HOST"; do
        dir=$TEST_WORK_DIR/nodes/$node
        xmllint --noout "$dir/yarn-site.xml" "$dir/mapred-site.xml"
        ! grep -q '@[A-Z_0-9]*@' "$dir/yarn-site.xml" "$dir/mapred-site.xml"
        test "$(xml_value "$dir/yarn-site.xml" yarn.resourcemanager.hostname)" = "$TEST_NN_IP"
        test "$(xml_value "$dir/yarn-site.xml" yarn.log.server.url)" = "http://$TEST_NN_IP:19888/jobhistory/logs"
        test "$(xml_value "$dir/mapred-site.xml" mapreduce.jobhistory.address)" = "$TEST_NN_IP:10020"
        test "$(xml_value "$dir/mapred-site.xml" mapreduce.jobhistory.webapp.address)" = "$TEST_NN_IP:19888"
    done
    grep -q "^$TEST_NN_HOST: -n sed -i -E .*/$TEST_NN_IP" "$TEST_WORK_DIR/calls"
    grep -q "^$TEST_DN0_HOST: -n sed -i -E .*/$TEST_DN0_IP" "$TEST_WORK_DIR/calls"
    grep -q "^$TEST_DN1_HOST: -n sed -i -E .*/$TEST_DN1_IP" "$TEST_WORK_DIR/calls"
    ! grep -q '^edge: -n sed -i' "$TEST_WORK_DIR/calls"
}

check_nginx_site() {
    local site=$TEST_WORK_DIR/nginx-site
    ! grep -q '@[A-Z_0-9]*@' "$site"
    test "$(grep -c 'listen 127.0.0.1:' "$site")" = 7
    ! grep -E 'listen' "$site" | grep -vq '127.0.0.1'
    cmp <(grep -oE 'proxy_pass http://[^;]+' "$site") <(printf 'proxy_pass http://%s\n' \
        "$TEST_NN_IP:9870" "$TEST_NN_IP:8088" "$TEST_NN_IP:19888" "$TEST_NN_IP:9868" \
        "$TEST_NN_IP:8042" "$TEST_DN0_IP:8042" "$TEST_DN1_IP:8042")
}

configs_written() { ls "$TEST_WORK_DIR"/nodes/*/yarn-site.xml >/dev/null 2>&1; }

id() { test "$1" = -un; test "$TEST_MODE" = wrong_user && echo someone || echo "$TEST_SSH_USER"; }
hostname() { echo "$TEST_CURRENT_NODE"; }
getent() {
    test "$TEST_MODE" = hosts_loopback && { echo '127.0.1.1       STREAM'; return 0; }
    case "$2" in
        "$TEST_NN_HOST") echo "$TEST_NN_IP       STREAM $2" ;;
        "$TEST_DN0_HOST") echo "$TEST_DN0_IP       STREAM $2" ;;
        "$TEST_DN1_HOST") echo "$TEST_DN1_IP       STREAM $2" ;;
        *) return 2 ;;
    esac
}
sleep() { :; }
sudo() {
    echo "$TEST_CURRENT_NODE: $*" >> "$TEST_WORK_DIR/calls"
    case "$*" in
        '-n test -d /home/hadoop/hadoop-3.4.0/etc/hadoop')
            test "$TEST_MODE" != missing_hadoop || test "$TEST_CURRENT_NODE" != "$TEST_DN1_HOST" ;;
        '-n -u hadoop tee '*)
            mkdir -p "$TEST_WORK_DIR/nodes/$TEST_CURRENT_NODE"
            cat > "$TEST_WORK_DIR/nodes/$TEST_CURRENT_NODE/$(basename "$5")" ;;
        *'/bin/jps'*)
            test "$TEST_MODE" = namenode_down || echo '101 NameNode'
            echo '102 SecondaryNameNode'
            echo '103 DataNode' ;;
        *'/bin/yarn node -list')
            local n=3 i
            test "$TEST_MODE" != missing_nodemanager || n=2
            for i in $(seq 1 "$n"); do echo "node-$i:4242 RUNNING node-$i:8042 0"; done ;;
        *'/sbin/start-yarn.sh') echo MOCK_START_YARN ;;
        *'--daemon start historyserver') echo MOCK_START_HISTORY ;;
        '-n install -m 644 '*) cp "$5" "$TEST_WORK_DIR/nginx-site" ;;
        '-n nginx -t') echo MOCK_NGINX_TEST ;;
        '-n systemctl reload nginx') echo MOCK_NGINX_RELOAD ;;
        *) return 0 ;;
    esac
}
ssh() {
    local command target_index target
    command=${!#}
    test "$1" = -i && test "$2" = "$TEST_SSH_KEY" || { echo "Неожиданный ключ SSH: $2" >&2; return 99; }
    target_index=$(($# - 1))
    target=${!target_index}
    case "$target" in
        "$TEST_SSH_USER@$TEST_NN_HOST"|"$TEST_SSH_USER@$TEST_DN0_HOST"|"$TEST_SSH_USER@$TEST_DN1_HOST") ;;
        *) echo "Неожиданный SSH-пользователь или узел: $target" >&2; return 99 ;;
    esac
    TEST_CURRENT_NODE=${target#*@} bash -c "$command"
}
curl() {
    local url=${!#} code=200
    if [[ $url == "http://$TEST_NN_IP:8088/" ]]; then
        test "$TEST_MODE" != rm_down || return 7
        return 0
    fi
    [[ $url == http://127.0.0.1:* ]] || { echo "Неожиданный адрес curl: $url" >&2; return 99; }
    test "$TEST_MODE" != port_down || [[ $url != *:8043/ ]] || code=502
    echo "$code"
}
nginx() { echo 'nginx version: nginx/1.24.0 (mock)'; }
export -f id hostname getent sleep sudo ssh curl nginx
export TEST_MODE

reset_state; TEST_MODE=fresh
output=$(bash deploy-yarn.sh)
[[ $output == *MOCK_START_YARN* && $output == *MOCK_START_HISTORY* ]]
[[ $output == *'Готово: YARN запущен'* ]]
check_yarn_configs
echo 'PASS: deploy-yarn.sh — последовательность запуска (заглушки)'
echo 'PASS: yarn-site.xml и mapred-site.xml на 4 узлах соответствуют cluster.conf, /etc/hosts — свой IP на каждом узле'

for TEST_MODE in wrong_user missing_hadoop namenode_down hosts_loopback; do
    reset_state
    if output=$(bash deploy-yarn.sh 2>&1); then
        echo "Неожиданный успех: $TEST_MODE" >&2; exit 1
    fi
    ! configs_written
    [[ $output != *MOCK_START_YARN* ]]
    echo "PASS: deploy-yarn.sh останавливается при $TEST_MODE до записи конфигов"
done

reset_state; TEST_MODE=missing_nodemanager
if output=$(bash deploy-yarn.sh 2>&1); then echo 'Неожиданный успех: missing_nodemanager' >&2; exit 1; fi
[[ $output == *MOCK_START_YARN* && $output == *'Зарегистрировалось NodeManager: 2 из 3'* && $output != *'Готово:'* ]]
echo 'PASS: deploy-yarn.sh — ненулевой код, если зарегистрировались не все NodeManager'

reset_state; TEST_MODE=fresh
output=$(bash publish-web.sh)
[[ $output == *MOCK_NGINX_TEST* && $output == *MOCK_NGINX_RELOAD* ]]
check_nginx_site
tunnel=$(grep -E '^  ssh -N ' <<< "$output")
[[ $tunnel == *" $TEST_SSH_USER@$TEST_EDGE_HOST" ]]
test "$(grep -o -- '-L [0-9]*:localhost:[0-9]*' <<< "$tunnel" | grep -c .)" = 7
echo 'PASS: publish-web.sh — конфиг nginx: 7 демонов, только localhost, адреса из cluster.conf'
echo 'PASS: publish-web.sh — команда туннеля на edge из cluster.conf'

for TEST_MODE in wrong_user rm_down; do
    reset_state
    if output=$(bash publish-web.sh 2>&1); then echo "Неожиданный успех: $TEST_MODE" >&2; exit 1; fi
    test ! -e "$TEST_WORK_DIR/nginx-site"
    echo "PASS: publish-web.sh останавливается при $TEST_MODE до установки конфига"
done
reset_state; TEST_MODE=port_down
if output=$(bash publish-web.sh 2>&1); then echo 'Неожиданный успех: port_down' >&2; exit 1; fi
[[ $output == *'Порт 8043 не отвечает'* && $output != *'Готово.'* ]]
echo 'PASS: publish-web.sh — ненулевой код, если порт не отвечает'

mkdir -p "$test_workspace/no-conf/hw2"
cp -r deploy-yarn.sh publish-web.sh conf "$test_workspace/no-conf/hw2/"
for script in deploy-yarn.sh publish-web.sh; do
    if output=$(bash "$test_workspace/no-conf/hw2/$script" 2>&1); then echo "Неожиданный успех без cluster.conf: $script" >&2; exit 1; fi
    [[ $output == *'Нет ../hw1/cluster.conf'* ]]
done
echo 'PASS: без ../hw1/cluster.conf оба скрипта останавливаются с понятной ошибкой'

mkdir -p "$test_workspace/other-cluster/hw1" "$test_workspace/other-cluster/hw2"
cp -r deploy-yarn.sh publish-web.sh conf "$test_workspace/other-cluster/hw2/"
cat > "$test_workspace/other-cluster/hw1/cluster.conf" <<'CONFIG'
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
cd "$test_workspace/other-cluster/hw2"
configure_test ../hw1/cluster.conf
reset_state; TEST_MODE=fresh
output=$(bash deploy-yarn.sh)
[[ $output == *'Готово: YARN запущен'* ]]
check_yarn_configs
reset_state
output=$(bash publish-web.sh)
check_nginx_site
[[ $output == *" student@198.51.100.42"* ]]
echo 'PASS: другая подсеть, имена узлов, SSH-пользователь и путь ключа с пробелами'
cd "$WORK_DIR"
test "$(sha256sum conf/*)" = "$template_fingerprint"
echo 'PASS: шаблоны конфигурации не изменились'
echo 'Все проверки пройдены. SSH, sudo, curl и nginx использовали заглушки.'