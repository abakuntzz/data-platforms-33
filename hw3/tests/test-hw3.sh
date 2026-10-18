#!/usr/bin/env bash
# Только локальные заглушки: никакого настоящего SSH, sudo, wget, scp или beeline.
set -euo pipefail
trap 'echo "FAIL: строка $LINENO" >&2' ERR
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
WORK_DIR=$TEST_DIR/..
cd "$WORK_DIR"
test_workspace=$(mktemp -d /tmp/hive-hw03-tests.XXXXXX)
mock_bin=$test_workspace/bin
mkdir -p "$mock_bin"
if command -v xmllint >/dev/null; then
    ln -sf "$(command -v xmllint)" "$mock_bin/xmllint-real"
    printf '%s\n' '#!/usr/bin/env bash' 'exec "$(dirname "$0")/xmllint-real" "$@"' > "$mock_bin/xmllint"
else
    printf '%s\n' '#!/usr/bin/env bash' 'test "$1" = --noout' 'exit 0' > "$mock_bin/xmllint"
fi
chmod +x "$mock_bin/xmllint"
export PATH="$mock_bin:$PATH"
bash -n deploy-hive.sh
bash -n load-partitioned-data.sh
bash -n ../hw1/cluster.conf
xmllint --noout conf/hive-site.xml
echo 'PASS: синтаксис и шаблон hive-site.xml'

trap 'rm -rf "$test_workspace"' EXIT
export TEST_WORK_DIR=$test_workspace
template_fingerprint=$(sha256sum conf/* sql/* data/red/* data/blue/*)

configure_test() {
    export HOME=$test_workspace/home
    source "$1"
    mkdir -p "$(dirname "$SSH_KEY")"
    touch "$SSH_KEY"
    export TEST_SSH_USER=$SSH_USER TEST_SSH_KEY=$SSH_KEY TEST_NN_HOST=$NAMENODE_HOST TEST_NN_IP=$NAMENODE_IP
}
configure_test ../hw1/cluster.conf

reset_state() {
    rm -rf "$TEST_WORK_DIR/nodes" "$TEST_WORK_DIR/calls" "$TEST_WORK_DIR/downloads" "$TEST_WORK_DIR/nn"
    mkdir -p "$TEST_WORK_DIR/nodes" "$TEST_WORK_DIR/downloads"
    mkdir -p "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin/conf)"
    cp conf/hive-env.sh "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin/conf/hive-env.sh)"
    : > "$TEST_WORK_DIR/calls"
    export TEST_HS2_READY=1 TEST_HS2_RUNNING=0 TEST_METASTORE_EXISTS=0 TEST_HIVE_INSTALLED=0
}

xml_value() { xmllint --xpath "string(/configuration/property[name=\"$2\"]/value)" "$1"; }

check_hive_site_on_nn() {
    local site=$TEST_WORK_DIR/nodes/hive-site.xml
    xmllint --noout "$site"
    ! grep -q '@[A-Z_0-9]*@' "$site" || return 1
    test "$(xml_value "$site" hive.metastore.warehouse.dir)" = "hdfs://$TEST_NN_IP:9000/user/hive/warehouse"
    test "$(xml_value "$site" hive.server2.thrift.bind.host)" = "$TEST_NN_IP"
}

id() { test "$1" = -un; test "$TEST_MODE" = wrong_user && echo someone || echo "$TEST_SSH_USER"; }
wget() {
    echo "wget $*" >> "$TEST_WORK_DIR/calls"
    local dest= url=
    while [ $# -gt 0 ]; do
        case $1 in
            -P) dest=$2; shift 2 ;;
            --timeout=*|--tries=*) shift ;;
            *) url=$1; shift ;;
        esac
    done
    test -n "$dest" && test -n "$url" || return 0
    case "$url" in
        *apache-hive-4.0.0-alpha-2-bin.tar.gz.sha256)
            printf '%s  %s\n' 'deadbeef' 'apache-hive-4.0.0-alpha-2-bin.tar.gz' > "$dest/apache-hive-4.0.0-alpha-2-bin.tar.gz.sha256"
            ;;
        *apache-hive-4.0.0-alpha-2-bin.tar.gz)
            echo mock-hive-tarball > "$dest/apache-hive-4.0.0-alpha-2-bin.tar.gz"
            ;;
        *)
            echo "Неожиданный URL wget: $url" >&2
            return 99
            ;;
    esac
}
sha256sum() {
    test "$1" = -c || { echo "Неожиданный вызов sha256sum: $*" >&2; return 99; }
    return 0
}
scp() {
    echo "scp $*" >> "$TEST_WORK_DIR/calls"
    test "$TEST_MODE" != scp_fail || return 1
    _scp_dest=
    _scp_src=
    _scp_skip_next=0
    for _scp_opt in "$@"; do
        if [ "$_scp_skip_next" = 1 ]; then
            _scp_skip_next=0
            continue
        fi
        case "$_scp_opt" in
            -i|-P|-F) _scp_skip_next=1; continue ;;
            -o|-o*) continue ;;
            *@*:*)
                _scp_dest=$_scp_opt
                ;;
            *)
                if [ -f "$_scp_opt" ]; then
                    _scp_src=$_scp_opt
                fi
                ;;
        esac
    done
    if [[ "$_scp_dest" == *:* ]]; then
        _scp_rpath=${_scp_dest#*:}
        mkdir -p "$(dirname "$(nn_path "$_scp_rpath")")"
        cp -f "$_scp_src" "$(nn_path "$_scp_rpath")"
        if [[ "$_scp_rpath" == /tmp/* ]]; then
            mkdir -p "$(dirname "$_scp_rpath")"
            cp -f "$_scp_src" "$_scp_rpath"
        fi
    fi
    return 0
}
nn_path() { echo "$TEST_WORK_DIR/nn$1"; }

sudo() {
    echo "sudo $*" >> "$TEST_WORK_DIR/calls"
    if [ "$1" = -n ] && [ "$2" = -H ] && [ "$3" = -u ] && [ "$4" = hadoop ]; then
        shift 4
        if [ "$1" = tee ]; then
            local dest=${!#} file
            file=$(nn_path "$dest")
            mkdir -p "$(dirname "$file")"
            cat > "$file"
            case "$dest" in
                */hive-site.xml) cp "$file" "$TEST_WORK_DIR/nodes/hive-site.xml" ;;
            esac
            return 0
        fi
        if [[ "$1" == */bin/schematool ]]; then
            echo schematool >> "$TEST_WORK_DIR/calls"
            TEST_METASTORE_EXISTS=1
            return 0
        fi
        if [ "$1" = tar ]; then
            mkdir -p "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin/bin)"
            printf '%s\n' '#!/usr/bin/env bash' 'echo schematool >> "'"$TEST_WORK_DIR"'/calls"' > "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin/bin/schematool)"
            chmod +x "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin/bin/schematool)"
            return 0
        fi
        if [ "$1" = mv ]; then
            local src=$2 dst=$3
            [[ "$dst" == /home/hadoop/* ]] && dst=$(nn_path "$dst")
            mkdir -p "$(dirname "$dst")"
            command mv "$src" "$dst"
            return 0
        fi
        if [ "$1" = rm ]; then
            shift
            local path
            for path in "$@"; do
                case "$path" in
                    -*) continue ;;
                    /home/hadoop/*) command rm -f "$(nn_path "$path")" ;;
                    *) command rm -f "$path" ;;
                esac
            done
            return 0
        fi
        "$@"
        return $?
    fi
    case "$*" in
        '-n test -d /home/hadoop/hadoop-3.4.0/etc/hadoop')
            test "$TEST_MODE" != missing_hadoop ;;
        *'/bin/jps'*)
            test "$TEST_MODE" != namenode_down || return 0
            echo '101 org.apache.hadoop.hdfs.server.namenode.NameNode'
            ;;
        '-n -u hadoop tee '*)
            local dest=${!#} file
            file=$(nn_path "$dest")
            mkdir -p "$(dirname "$file")"
            cat > "$file"
            ;;
        '-n install -o hadoop -g hadoop -d '*)
            mkdir -p "$(nn_path "${!#}")"
            ;;
        *)
            return 0 ;;
    esac
}
ssh() {
    local command target
    test "$1" = -i && test "$2" = "$TEST_SSH_KEY" || { echo "Неожиданный SSH: $*" >&2; return 99; }
    target=$TEST_SSH_USER@$TEST_NN_HOST
    case "$*" in
        *"$target"*) ;;
        *) echo "Неожиданный узел SSH: $*" >&2; return 99 ;;
    esac
    echo "ssh $*" >> "$TEST_WORK_DIR/calls"
    test "$TEST_MODE" != ssh_fail || return 255
    TEST_CURRENT_NODE=$TEST_NN_HOST
    _ssh_prev=
    _ssh_bash_se=0
    for _ssh_arg in "$@"; do
        if [ "$_ssh_prev" = bash ] && [ "$_ssh_arg" = -se ]; then
            _ssh_bash_se=1
        fi
        _ssh_prev=$_ssh_arg
    done
    if [ "$_ssh_bash_se" = 1 ]; then
        bash -se
    else
        command=${!#}
        bash -c "$command"
    fi
}
pgrep() {
    if [[ "$*" == *HiveServer2* ]]; then
        test "$TEST_HS2_RUNNING" = 1 && echo 999 || return 1
    fi
    return 1
}
pkill() { TEST_HS2_RUNNING=0; return 0; }
sleep() { :; }
hdfs() {
    echo "hdfs $*" >> "$TEST_WORK_DIR/calls"
    return 0
}
beeline() {
    echo "beeline $*" >> "$TEST_WORK_DIR/calls"
    test "$TEST_HS2_READY" = 1 || return 1
    return 0
}
hive() {
    echo "hive $*" >> "$TEST_WORK_DIR/calls"
    return 0
}
tail() { :; }
source() {
    local file=$1
    case "$file" in
        /home/hadoop/*) file=$(nn_path "$file") ;;
    esac
    builtin source "$file"
}
test() {
    if [[ "$*" == *metastore_db* ]]; then
        test "$TEST_METASTORE_EXISTS" = 0
        return $?
    fi
    if [[ "$*" == */apache-hive-4.0.0-alpha-2-bin ]]; then
        test -d "$(nn_path /home/hadoop/apache-hive-4.0.0-alpha-2-bin)"
        return $?
    fi
    command test "$@"
}
export -f id wget sha256sum scp sudo ssh pgrep pkill sleep hdfs beeline hive tail source test nn_path
export TEST_MODE

reset_state; TEST_MODE=fresh
output=$(bash deploy-hive.sh)
[[ $output == *'HiveServer2 отвечает на порту 10000'* ]]
[[ $output == *'Готово: Hive 4.0.0-alpha-2'* ]]
grep -q 'schematool -dbType derby -initSchema' "$TEST_WORK_DIR/calls" || grep -q 'hive --service hiveserver2' "$TEST_WORK_DIR/calls"
check_hive_site_on_nn
grep -q 'wget.*apache-hive-4.0.0-alpha-2-bin.tar.gz.sha256' "$TEST_WORK_DIR/calls"
echo 'PASS: deploy-hive.sh — установка и HiveServer2 (заглушки)'

for TEST_MODE in wrong_user missing_hadoop namenode_down scp_fail ssh_fail; do
    reset_state
    TEST_HS2_READY=0
    if output=$(bash deploy-hive.sh 2>&1); then
        echo "Неожиданный успех deploy: $TEST_MODE" >&2
        exit 1
    fi
    [[ $output != *'Готово:'* ]]
    echo "PASS: deploy-hive.sh останавливается при $TEST_MODE"
done

reset_state; TEST_MODE=fresh; TEST_HS2_READY=0
if output=$(bash deploy-hive.sh 2>&1); then echo 'Неожиданный успех: hs2_down' >&2; exit 1; fi
[[ $output == *'HiveServer2 не готов'* ]]
echo 'PASS: deploy-hive.sh — ненулевой код, если HiveServer2 не отвечает'

reset_state; TEST_MODE=fresh
output=$(bash load-partitioned-data.sh)
[[ $output == *'Готово: данные загружены'* ]]
grep -q 'hdfs dfs -put' "$TEST_WORK_DIR/calls"
grep -q 'beeline.*partitioned-colours.hql' "$TEST_WORK_DIR/calls"
grep -q 'SHOW PARTITIONS test.colours' "$TEST_WORK_DIR/calls"
echo 'PASS: load-partitioned-data.sh — HDFS и Beeline (заглушки)'

for TEST_MODE in wrong_user ssh_fail; do
    reset_state; TEST_HS2_READY=0
    if output=$(bash load-partitioned-data.sh 2>&1); then
        echo "Неожиданный успех load: $TEST_MODE" >&2
        exit 1
    fi
    [[ $output != *'Готово:'* ]]
    echo "PASS: load-partitioned-data.sh останавливается при $TEST_MODE"
done

reset_state; TEST_HS2_READY=0; TEST_MODE=fresh
if output=$(bash load-partitioned-data.sh 2>&1); then echo 'Неожиданный успех: hs2_down load' >&2; exit 1; fi
[[ $output == *'HiveServer2'* || $output == *'beeline'* ]]
echo 'PASS: load-partitioned-data.sh — ненулевой код без HiveServer2'

mkdir -p "$test_workspace/no-conf/hw3"
cp -r deploy-hive.sh load-partitioned-data.sh conf sql data "$test_workspace/no-conf/hw3/"
for script in deploy-hive.sh load-partitioned-data.sh; do
    if output=$(bash "$test_workspace/no-conf/hw3/$script" 2>&1); then
        echo "Неожиданный успех без cluster.conf: $script" >&2
        exit 1
    fi
    [[ $output == *'Нет ../hw1/cluster.conf'* ]]
done
echo 'PASS: без ../hw1/cluster.conf оба скрипта останавливаются с понятной ошибкой'

mkdir -p "$test_workspace/other-cluster/hw1" "$test_workspace/other-cluster/hw3"
cp -r deploy-hive.sh load-partitioned-data.sh conf sql data tests "$test_workspace/other-cluster/hw3/"
cat > "$test_workspace/other-cluster/hw1/cluster.conf" <<'CONFIG'
EDGE_HOST=198.51.100.42
EDGE_SSH_KEY="$HOME/.ssh/other edge key"
SSH_USER=student
SSH_KEY="$HOME/.ssh/other internal key"
NAMENODE_HOST=course-nn
NAMENODE_IP=10.71.0.21
DATANODE_0_HOST=course-dn0
DATANODE_0_IP=10.71.0.22
DATANODE_1_HOST=course-dn1
DATANODE_1_IP=10.71.0.23
CONFIG
cd "$test_workspace/other-cluster/hw3"
configure_test ../hw1/cluster.conf
reset_state; TEST_MODE=fresh
output=$(bash deploy-hive.sh)
check_hive_site_on_nn
test "$(xml_value "$TEST_WORK_DIR/nodes/hive-site.xml" hive.server2.thrift.bind.host)" = 10.71.0.21
echo 'PASS: другой NAMENODE_IP подставляется в hive-site.xml'

cd "$WORK_DIR"
test "$(sha256sum conf/* sql/* data/red/* data/blue/*)" = "$template_fingerprint"
echo 'PASS: шаблоны конфигурации и SQL не изменились'
echo 'Все проверки пройдены. SSH, sudo, wget, scp и beeline использовали заглушки.'
