# ДЗ №3: Apache Hive и партиционированная загрузка

`deploy-hive.sh` устанавливает Apache Hive 4.0.0-alpha-2 на NameNode, инициализирует metastore Derby
и запускает **HiveServer2** — клиенты подключаются через JDBC/Beeline, без embedded-режима `hive` CLI.
`load-partitioned-data.sh` кладёт файлы в HDFS и через Beeline создаёт партиционированную таблицу `test.colours`
с загрузкой по разделам `colour=red` и `colour=blue`.

Шаблоны лежат в `conf/`, адреса подставляются из `../hw1/cluster.conf`; `hw1` и `hw3` должны быть рядом, как в репозитории.
Ручной вариант тех же шагов — в `HadoopGuide.txt`.

## Запуск

Нужны работающие HDFS (ДЗ1) и, для MapReduce-запросов Hive, YARN (ДЗ2). На edge под `SSH_USER`:

```bash
git clone https://github.com/abakuntzz/data-platforms-33.git   # или git pull, если уже скачан
cd data-platforms-33/hw3
bash deploy-hive.sh
bash load-partitioned-data.sh
```

`deploy-hive.sh` скачивает дистрибутив с проверкой [SHA-256](https://archive.apache.org/dist/hive/hive-4.0.0-alpha-2/apache-hive-4.0.0-alpha-2-bin.tar.gz.sha256),
распаковывает его в `/home/hadoop/apache-hive-4.0.0-alpha-2-bin` на NameNode, настраивает каталоги HDFS
(`/tmp`, `/user/hive/warehouse`), один раз выполняет `schematool -initSchema` и поднимает HiveServer2 на порту 10000.
Повторный запуск безопасен: повторная распаковка и initSchema пропускаются, если каталоги уже есть;
перед стартом останавливается прежний процесс HiveServer2.

Metastore Derby хранится в `/home/hadoop/hive-hw03/metastore_db` на NameNode (не в embedded-сессии Beeline).

## Проверка

На NameNode под `SSH_USER` — два независимых клиента Beeline к одному HiveServer2:

```bash
sudo -u hadoop bash -c 'source /home/hadoop/apache-hive-4.0.0-alpha-2-bin/conf/hive-env.sh
  beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "SHOW PARTITIONS test.colours;"' &
sudo -u hadoop bash -c 'source /home/hadoop/apache-hive-4.0.0-alpha-2-bin/conf/hive-env.sh
  beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "SELECT colour, number FROM test.colours ORDER BY colour, number;"'
wait
```

Ожидаются разделы `colour=red` и `colour=blue` и четыре строки данных (3, 5, 7, 11).

С компьютера через SSH-туннель на HiveServer2:

```bash
source hw1/cluster.conf
ssh -N -i "$EDGE_SSH_KEY" -L 10000:$NAMENODE_IP:10000 "$SSH_USER@$EDGE_HOST"
```

В другом терминале на edge (если установлен клиент Hive) или на NN:

```bash
beeline -u "jdbc:hive2://127.0.0.1:10000" -n hadoop -e "SELECT * FROM test.colours;"
```

Лог HiveServer2: `/tmp/hive-hw03-hs2.log` на NameNode.

Остановка HiveServer2 (как в `HadoopGuide.txt`):

```bash
sudo -u hadoop pkill -f org.apache.hive.service.server.HiveServer2
```

## Тесты

На edge или локально, из папки `hw3`:

```bash
sudo apt-get install -y libxml2-utils   # если ещё нет xmllint
bash tests/test-hw3.sh
```

SSH, sudo, wget, scp и beeline заменены заглушками; на VM ничего не выполняется. Проверяются синтаксис,
подстановка IP в `hive-site.xml`, последовательность развёртывания и загрузки, отказ при типичных ошибках.
