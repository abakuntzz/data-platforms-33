# ДЗ №5: поток Prefect со Spark под YARN

Поток `hw5-colours-stats` (`flow.py`) запускает Spark под YARN, читает TSV из HDFS,
чистит `colour`, переводит `number` в `int`, считает `count`/`max`/`sum`/`avg` по цвету,
добавляет `processed_at` и сохраняет таблицу Hive `hw5.colours_stats` с партициями по `colour`.
Последний шаг проверяет таблицу через Beeline.

Нужны HDFS, YARN, Hive и Spark из ДЗ1–4. Пути и адреса — в `hw5-env.sh`.

## Запуск

С компьютера, с пробросом веб-интерфейса Prefect:

```bash
ssh -i ~/.ssh/id_ed25519_course -L 4200:localhost:4200 team@171.22.75.75
```

На edge всё выполняется от `hadoop`: у него лежат Spark из ДЗ4 и SSH-ключ до узлов.
Домашняя папка `team` закрыта для `hadoop`, поэтому он клонирует свою копию репозитория:

```bash
sudo -i -u hadoop
git clone https://github.com/abakuntzz/data-platforms-33.git   # первый раз, дальше git pull
cd data-platforms-33/hw5
bash run-hw5.sh
```

`run-hw5.sh` ставит Prefect (`prepare-prefect.sh`), загружает данные в HDFS (`load-data.sh`),
запускает сервер Prefect (`start-prefect-server.sh`) и поток (`run-flow.sh`).

## Проверка

`http://localhost:4200` → Runs: все шесть шагов `Completed`. Ожидаемая таблица:

| colour | row_count | max_number | sum_number | avg_number |
|---|---|---|---|---|
| blue | 3 | 9 | 18 | 6.0 |
| green | 3 | 8 | 15 | 5.0 |
| red | 3 | 8 | 13 | 4.33 |

Остановить сервер: `bash stop-prefect-server.sh`.