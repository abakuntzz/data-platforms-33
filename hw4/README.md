# ДЗ №4: Apache Spark под YARN

Spark 3.5.9 под YARN: драйвер на edge, исполнители на узлах кластера.
Данные из HDFS сохраняются в Parquet-таблицу `hw4.colours_report`, партиции — по `colour`.

Нужны Java 11, работающие HDFS/YARN из ДЗ1–2, Hive из ДЗ3 и SSH с edge под `SSH_USER` с `sudo`.
Проверьте адреса и SSH-ключ в `../hw1/cluster.conf`, настройки Metastore — в `../hw3/cluster.conf`.
IP edge указан в `run-spark.sh`. Репозиторий нужен целиком: `hw1`, `hw3` и `hw4` должны быть рядом.

На edge, из корня репозитория:

```bash
cd hw4
bash run-hw4.sh
```

Скрипт готовит Spark и Python 3.11, загружает TSV и проверяет через Beeline 3 строки и 3 партиции.
В Spark: `number` → `int`, фильтр `number > 0`, затем `max` и `count` по цвету.
Повторный запуск заменяет входной файл и результат ДЗ4.

Проверка результата отдельно: `bash verify-report.sh`.
