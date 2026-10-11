#!/usr/bin/env bash
set -euo pipefail

CONF=conf/nginx-hadoop.conf
PORTS="9870 8088 19888 9868 8042 8043 8044 9864 9865 9866"

cd "$(dirname "$0")"
test -f ../hw1/cluster.conf || { echo "Нет ../hw1/cluster.conf: запускайте из репозитория (hw1 и hw2 рядом)" >&2; exit 1; }
source ../hw1/cluster.conf

render() {
    sed -e "s/@NAMENODE_IP@/$NAMENODE_IP/g" \
        -e "s/@NAMENODE_HOST@/$NAMENODE_HOST/g" \
        -e "s/@DATANODE_0_IP@/$DATANODE_0_IP/g" \
        -e "s/@DATANODE_0_HOST@/$DATANODE_0_HOST/g" \
        -e "s/@DATANODE_1_IP@/$DATANODE_1_IP/g" \
        -e "s/@DATANODE_1_HOST@/$DATANODE_1_HOST/g" "$1"
}
log() { echo; echo "=== $*"; }

log "1. Проверки"
test "$(id -un)" = "$SSH_USER" || { echo "Запускать под пользователем $SSH_USER" >&2; exit 1; }
test -f "$SSH_KEY" || { echo "Нет $SSH_KEY: запускайте на edge" >&2; exit 1; }
test -f "$CONF" || { echo "Нет файла $CONF рядом со скриптом" >&2; exit 1; }
curl -s -o /dev/null -m 5 "http://$NAMENODE_IP:8088/" \
    || { echo "ResourceManager недоступен с edge. Сначала bash deploy-yarn.sh" >&2; exit 1; }
echo "Внутренние интерфейсы доступны с edge"

log "2. Установка nginx"
command -v nginx >/dev/null || { sudo -n apt-get update; sudo -n apt-get install -y nginx; }
nginx -v

log "3. Конфиг nginx"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
render "$CONF" > "$work_dir/hadoop"
! grep -q '@[A-Z_0-9]*@' "$work_dir/hadoop" || { echo "В $CONF остались неподставленные метки" >&2; exit 1; }
sudo -n install -m 644 "$work_dir/hadoop" /etc/nginx/sites-available/hadoop
sudo -n ln -sfn /etc/nginx/sites-available/hadoop /etc/nginx/sites-enabled/hadoop
sudo -n nginx -t
sudo -n systemctl enable --now nginx
sudo -n systemctl reload nginx

log "4. Проверка: каждый порт на localhost edge отвечает страницей демона"
for p in $PORTS; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$p/" || true)
    echo "порт $p -> HTTP $code"
    case "$code" in 2??|3??) ;; *) echo "Порт $p не отвечает, проверьте sudo nginx -T и что демон запущен" >&2; exit 1 ;; esac
done

log "Готово. На своём компьютере из корня репозитория откройте туннель:"
echo "  source hw1/cluster.conf"
echo "  ssh -N -i \"\$EDGE_SSH_KEY\" $(for p in $PORTS; do printf -- '-L %s:localhost:%s ' "$p" "$p"; done)\"\$SSH_USER@\$EDGE_HOST\""
echo "и зайдите в браузере:"
echo "  NameNode         http://localhost:9870"
echo "  ResourceManager  http://localhost:8088"
echo "  JobHistory       http://localhost:19888"
echo "  SecondaryNN      http://localhost:9868"
echo "  NodeManager      http://localhost:8042  :8043  :8044  (nn, 00, 01)"
echo "  DataNode         http://localhost:9864  :9865  :9866  (nn, 00, 01)"
