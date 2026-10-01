#!/usr/bin/env bash
# Только локальные заглушки: никакого настоящего SSH, sudo или скачивания.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
WORK_DIR=$TEST_DIR/..
SCRIPT=$WORK_DIR/deploy-hdfs.sh
bash -n "$SCRIPT"
bash -n "$WORK_DIR/prepare-node.sh"
xmllint --noout "$WORK_DIR/hw01-conf/core-site.xml" "$WORK_DIR/hw01-conf/hdfs-site.xml"
test "$(awk 'END {print NR}' "$WORK_DIR/hw01-conf/workers")" = 3
echo 'PASS: синтаксис и конфиги'

id() { test "$1" = -un; echo team; }
sudo() {
    case "$*" in
        '-n test ! -e /home/hadoop') test "$TEST_MODE" != existing_home ;;
        '-n test ! -e /tmp/hadoop-hadoop') test "$TEST_MODE" != legacy_data ;;
        '-n test ! -e /home/hadoop/hdfs-hw01/name') test "$TEST_MODE" != existing_metadata ;;
        '-n apt-get install '*) test "$TEST_MODE" != package_error || return 17 ;;
        '-n passwd hadoop') test "$TEST_MODE" != password_error || return 18; echo MOCK_PASSWORD ;;
        '-n cat /home/hadoop/.ssh/id_ed25519.pub') echo 'ssh-ed25519 FAKE_PUBLIC_KEY' ;;
        *'namenode -format -nonInteractive') echo MOCK_FORMAT ;;
        *'/sbin/start-dfs.sh') echo MOCK_START ;;
        *) return 0 ;;
    esac
}
ssh() {
    local command
    command=${!#}
    case "$command" in
        'bash -se')
            local payload
            payload=$(cat)
            bash -n <<< "$payload"
            bash -se <<< "$payload" ;;
        'sudo -n passwd hadoop')
            [[ " $* " == *' -t '* ]] || { echo 'Для passwd нужен SSH с терминалом' >&2; return 99; }
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
wget() { return 0; }
sha512sum() { return 0; }
export -f id sudo ssh wget sha512sum
export TEST_MODE

TEST_MODE=fresh
output=$(bash "$SCRIPT" --init-hdfs)
[[ $output == *MOCK_FORMAT* && $output == *MOCK_START* ]]
echo 'PASS: последовательность первого запуска (заглушки)'
test "$(grep -c '^MOCK_PASSWORD$' <<< "$output")" = 4
echo 'PASS: пароль задаётся на четырёх узлах, удалённый passwd получает терминал'
for TEST_MODE in existing_home legacy_data existing_metadata package_error password_error remote_password_error; do
    if output=$(bash "$SCRIPT" --init-hdfs 2>&1); then
        echo "Неожиданный успех: $TEST_MODE" >&2; exit 1
    fi
    [[ $output != *MOCK_FORMAT* && $output != *MOCK_START* ]]
    echo "PASS: остановка при $TEST_MODE"
done
if output=$(bash "$SCRIPT" 2>&1); then echo 'Не запрошен --init-hdfs' >&2; exit 1; fi
[[ $output != *MOCK_FORMAT* && $output != *MOCK_START* ]]
echo 'PASS: явное разрешение на установку'
echo 'Все проверки пройдены. На ВМ ничего не выполнялось.'
