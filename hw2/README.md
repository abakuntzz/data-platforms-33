# ДЗ №2: YARN и публикация веб-интерфейсов

`deploy-yarn.sh` разворачивает YARN и MapReduce JobHistory Server поверх HDFS из ДЗ1.
`publish-web.sh` публикует веб-интерфейсы демонов через nginx на edge.
Шаблоны конфигурации лежат в `conf/`, адреса подставляются из `../hw1/cluster.conf`,
поэтому `hw1` и `hw2` должны лежать рядом, как в репозитории.

Схема: ResourceManager, NodeManager и History Server на `NAMENODE_HOST`, NodeManager на двух DataNode, nginx на edge.

## Запуск

Нужен работающий HDFS из ДЗ1. На edge под `SSH_USER`:

```bash
git clone https://github.com/abakuntzz/data-platforms-33.git   # или git pull, если уже скачан
cd data-platforms-33/hw2
bash deploy-yarn.sh
bash publish-web.sh
```

`deploy-yarn.sh` проверяет, что NameNode запущен, прописывает в `/etc/hosts` внутренние IP узлов
вместо `127.0.1.1`, раскладывает конфиги на четыре VM и перезапускает YARN и History Server.
Завершается успешно, только если зарегистрировались три NodeManager и отвечает API History Server. Исходные файлы сохраняются
как `*.bak-hw2`. Повторный запуск безопасен, HDFS не затрагивается.

Каждый NodeManager отдаёт YARN 1024 МБ и 2 vcores, контейнеры MapReduce получают по 512 МБ:
на VM 4 ГБ и 2 ядра без swap, а на NN уже работают демоны HDFS, ResourceManager и History Server.

`publish-web.sh` ставит nginx и включает конфиг, по которому localhost edge проксируется на демоны:
NameNode (9870), ResourceManager (8088), JobHistory (19888), SecondaryNameNode (9868),
NodeManager (8042, 8043, 8044), DataNode (9864, 9865, 9866). Порты NodeManager и DataNode перечислены
в порядке NN, DataNode-0, DataNode-1. nginx слушает только localhost edge; доступ — через SSH-туннель.
Внутренние адреса в ссылках, JSON и HTTP-редиректах заменяются на соответствующие адреса localhost.

**`hw1/deploy-hdfs.sh` предназначен для первичного развёртывания**: при существующей установке он завершится до изменений.
Для запуска существующего HDFS используйте `hw1/hadoop-guide.txt`, без форматирования.

## Проверка

На компьютере, из корня репозитория:

```bash
source hw1/cluster.conf
ssh -N -i "$EDGE_SSH_KEY" -L 9870:localhost:9870 -L 8088:localhost:8088 -L 19888:localhost:19888 \
    -L 9868:localhost:9868 -L 8042:localhost:8042 -L 8043:localhost:8043 -L 8044:localhost:8044 \
    -L 9864:localhost:9864 -L 9865:localhost:9865 -L 9866:localhost:9866 \
    "$SSH_USER@$EDGE_HOST"
```

В `http://localhost:8088` → Nodes должно быть три узла `RUNNING`, в `http://localhost:9870` — три live DataNode.
Переходы к NodeManager и DataNode должны открывать соответствующие страницы localhost.
Тестовая задача (на NN под `SSH_USER`):

```bash
sudo -u hadoop /home/hadoop/hadoop-3.4.0/bin/yarn jar \
    /home/hadoop/hadoop-3.4.0/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.0.jar pi 3 100
```

Задача должна завершиться со статусом `SUCCEEDED` и появиться в `http://localhost:19888`.

После перезагрузки VM: запустить HDFS по `hw1/hadoop-guide.txt` (без format), затем `bash deploy-yarn.sh`.

## Тесты

```bash
bash hw2/tests/test-hw2.sh
```

SSH, sudo, curl и nginx заменены заглушками, на VM ничего не выполняется. Проверяются сгенерированные
конфиги, остановка при ошибках и запуск с другим `cluster.conf`. Нужны `xmllint` и `sha256sum`.
