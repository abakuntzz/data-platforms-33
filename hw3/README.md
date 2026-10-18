# ДЗ №3: Apache Hive и партиционированная загрузка

`deploy-hive.sh` устанавливает Apache Hive 4.0.0-alpha-2 на NameNode, инициализирует metastore Derby
и запускает **HiveServer2** — клиенты подключаются через JDBC/Beeline, без embedded-режима `hive` CLI.
Скрипт также автоматически создаёт **партиционированную таблицу** `test.colours`
и загружает в неё данные с разбиением по разделам `colour=<значение>`.

Шаблоны лежат в `conf/`, адреса подставляются из `../hw1/cluster.conf`; `hw1` и `hw3` должны быть рядом, как в репозитории.
Ручной вариант тех же шагов — в `HadoopGuide.txt`.

## Запуск

Нужны работающие HDFS (ДЗ1) и, для MapReduce-запросов Hive, YARN (ДЗ2). На edge под `SSH_USER`:

```bash
git clone https://github.com/abakuntzz/data-platforms-33.git   # или git pull, если уже скачан
cd data-platforms-33/hw3
bash deploy-hive.sh