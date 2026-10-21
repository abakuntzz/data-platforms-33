import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

hdfs = sys.argv[1]
spark = (
    SparkSession.builder
    .appName("hw4-colours-report")
    .config("spark.sql.warehouse.dir", f"{hdfs}/user/hive/warehouse")
    .enableHiveSupport()
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

try:
    assert spark.sparkContext.master == "yarn", "Нужен запуск через YARN"
    print("YARN application:", spark.sparkContext.applicationId)

    # Читаем заранее загруженный TSV из HDFS. Сначала обе колонки — строки.
    source = spark.read.csv(
        f"{hdfs}/user/hadoop/hw04/input/colours.tsv",
        sep="\t",
        header=True,
    )

    # Преобразуем тип, фильтруем и считаем показатели для каждого цвета.
    numbers = source.withColumn("number", F.col("number").cast("int"))
    positive = numbers.filter(F.col("number") > 0)
    report = positive.groupBy("colour").agg(
        F.max("number").alias("max_number"),
        F.count("*").alias("row_count"),
    )

    # Данные — в HDFS, описание таблицы и партиций — в общем Hive Metastore.
    spark.sql("CREATE DATABASE IF NOT EXISTS hw4")
    (
        report.write
        .mode("overwrite")
        .format("parquet")
        .option("path", f"{hdfs}/user/hadoop/hw04/output/colours_report")
        .partitionBy("colour")
        .saveAsTable("hw4.colours_report")
    )
    spark.table("hw4.colours_report").orderBy("colour").show()
finally:
    spark.stop()
