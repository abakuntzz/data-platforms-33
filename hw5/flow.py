import os
import subprocess

from prefect import flow, get_run_logger, task
from prefect.cache_policies import NO_CACHE
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

HDFS_URL = os.environ["HDFS_URL"]

# Общие задачи

@task(name="1-start-spark", cache_policy=NO_CACHE)
def start_spark(app_name):
    logger = get_run_logger()

    spark = (
        SparkSession.builder
        .appName(app_name)
        .master("yarn")
        .config("spark.submit.deployMode", "client")
        .config("spark.driver.host", os.environ["EDGE_IP"])
        .config("spark.driver.memory", "1g")
        .config("spark.executor.instances", "1")
        .config("spark.executor.cores", "1")
        .config("spark.executor.memory", "512m")
        .config("spark.executor.memoryOverhead", "384")
        .config("spark.yarn.am.memory", "512m")
        .config("spark.yarn.am.memoryOverhead", "384")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.default.parallelism", "1")
        .config(
            "spark.yarn.dist.archives",
            f"{os.environ['HW4_RUNTIME']}/python.tar.gz#python-env",
        )
        .config(
            "spark.hadoop.hive.metastore.uris",
            f"thrift://127.0.0.1:{os.environ['METASTORE_LOCAL_PORT']}",
        )
        .config("spark.sql.warehouse.dir", f"{HDFS_URL}/user/hive/warehouse")
        .enableHiveSupport()
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    master = spark.sparkContext.master
    if master != "yarn":
        raise RuntimeError(f"Ожидался master=yarn, а получили {master}")
    logger.info("Spark %s запущен в YARN, приложение %s",
                spark.version, spark.sparkContext.applicationId)
    return spark


@task(name="2-check-hdfs-file", cache_policy=NO_CACHE)
def check_hdfs_file(spark, path):
    logger = get_run_logger()

    jvm = spark._jvm
    hadoop_conf = spark._jsc.hadoopConfiguration()
    hdfs_path = jvm.org.apache.hadoop.fs.Path(path)
    fs = hdfs_path.getFileSystem(hadoop_conf)

    if not fs.exists(hdfs_path):
        raise FileNotFoundError(f"В HDFS нет {path}, сначала выполните load-data.sh")

    status = fs.getFileStatus(hdfs_path)
    logger.info("HDFS доступен: %s, файл %s, %d байт, репликация %d",
                fs.getUri().toString(), path, status.getLen(), status.getReplication())


@task(name="3-read-tsv", cache_policy=NO_CACHE)
def read_tsv(spark, path):
    logger = get_run_logger()

    df = spark.read.csv(path, sep="\t", header=True)

    logger.info("Прочитано строк: %d, схема: %s", df.count(), df.schema.simpleString())
    return df


@task(name="5-save-table", cache_policy=NO_CACHE)
def save_table(spark, df, table, path, partition_by):
    logger = get_run_logger()

    database = table.split(".")[0]
    spark.sql(f"CREATE DATABASE IF NOT EXISTS {database}")
    (
        df.write
        .mode("overwrite")
        .format("parquet")
        .option("path", path)
        .partitionBy(partition_by)
        .saveAsTable(table)
    )

    partitions = [row[0] for row in spark.sql(f"SHOW PARTITIONS {table}").collect()]
    logger.info("Таблица %s записана в %s, партиции: %s", table, path, partitions)


@task(name="6-check-with-hive", cache_policy=NO_CACHE)
def check_with_hive(table, columns, expected_rows):
    logger = get_run_logger()

    query = f"SELECT {', '.join(columns)} FROM {table}"
    hive_home = os.environ["HIVE_HOME_ON_NN"]
    remote_command = (
        f"source {hive_home}/conf/hive-env.sh && "
        f"export HIVE_CONF_DIR={hive_home}/conf && "
        f"beeline -u {os.environ['HIVE_JDBC']} -n hadoop "
        f"--silent=true --showHeader=false --outputformat=tsv2 "
        f"-e '{query}'"
    )
    result = subprocess.run(
        ["ssh", "-i", os.path.expanduser("~/.ssh/id_ed25519"), "-o", "BatchMode=yes",
         f"hadoop@{os.environ['NAMENODE_HOST']}", remote_command],
        capture_output=True, text=True, timeout=180,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Beeline завершился с ошибкой:\n{result.stderr[-2000:]}")

    logger.info("Ответ Beeline:\n%s", result.stdout)

    actual = [tuple(line.split("\t")) for line in result.stdout.splitlines() if line.strip()]
    if sorted(actual) != sorted(expected_rows):
        raise ValueError(f"Hive вернул {sorted(actual)},\nа Spark записал {sorted(expected_rows)}")
    logger.info("Hive читает таблицу %s, данные совпадают со Spark", table)

# Конкретная задача

@task(name="4-transform", cache_policy=NO_CACHE)
def transform(raw):
    logger = get_run_logger()

    cleaned = (
        raw
        .withColumn("colour", F.lower(F.trim(F.col("colour"))))
        .withColumn("number", F.col("number").cast("int"))
        .filter(F.col("number") > 0)
    )

    stats = (
        cleaned
        .groupBy("colour")
        .agg(
            F.count("*").alias("row_count"),
            F.max("number").alias("max_number"),
            F.sum("number").alias("sum_number"),
            F.round(F.avg("number"), 2).alias("avg_number"),
        )
        .withColumn("processed_at", F.current_timestamp())
    )

    for row in stats.orderBy("colour").collect():
        logger.info("%s", row.asDict())
    return stats


# Поток

@flow(name="hw5-colours-stats", log_prints=True)
def hw5_flow(
    input_path: str = f"{HDFS_URL}/user/hadoop/hw05/input/colours.tsv",
    table: str = "hw5.colours_stats",
    output_path: str = f"{HDFS_URL}/user/hadoop/hw05/output/colours_stats",
    partition_by: str = "colour",
):
    spark = start_spark("hw5-prefect-colours-stats")
    try:
        check_hdfs_file(spark, input_path)
        raw = read_tsv(spark, input_path)
        stats = transform(raw)
        save_table(spark, stats, table, output_path, partition_by)

        columns = [c for c in stats.columns if c != "processed_at"]
        expected_rows = [tuple(str(value) for value in row)
                         for row in stats.select(columns).collect()]
    finally:
        spark.stop()

    check_with_hive(table, columns, expected_rows)


if __name__ == "__main__":
    hw5_flow()
