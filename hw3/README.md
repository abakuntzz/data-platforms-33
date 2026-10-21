# ДЗ №3: Apache Hive и партиционированная загрузка

Hive 4.0.0-alpha-2 на NameNode: Beeline → HiveServer2 → отдельный Metastore → Derby.
Данные загружаются через промежуточную таблицу в `test.colours`, партиции — по `colour`.

Нужны Java 11, работающие HDFS/YARN из ДЗ1–2 и SSH с edge под `SSH_USER` с `sudo` на узлах.
Проверьте адреса и SSH-ключ в `../hw1/cluster.conf`, настройки Metastore — в `cluster.conf`.
Репозиторий нужен целиком: `hw1` и `hw3` должны быть рядом.

На edge, из корня репозитория:

```bash
cd hw3
bash deploy-hive.sh
```

Скрипт создаёт учебный TSV при его отсутствии и проверяет 10 правильных строк без `NULL` и 10 партиций.
Повторный запуск пересоздаёт `test.colours` и `test.colours_staging`.
Переход со старой embedded-схемы требует согласованной остановки прежнего HiveServer2.

Подключение и проверка двух клиентов: [hive-guide.txt](hive-guide.txt).
