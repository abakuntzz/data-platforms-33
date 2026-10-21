import sys

from pyspark.sql import SparkSession

hdfs = sys.argv[1]
spark = (
    SparkSession.builder
    .appName("hw4-check")
    .config("spark.sql.warehouse.dir", f"{hdfs}/user/hive/warehouse")
    .enableHiveSupport()
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

try:
    assert spark.sparkContext.master == "yarn", "Нужен запуск через YARN"
    print("YARN application:", spark.sparkContext.applicationId)

    # Проверяем работу Python на исполнителе, а не только запуск драйвера.
    numbers = spark.createDataFrame([(1,), (2,), (3,)], ["number"])
    assert numbers.count() == 3, "Не выполнено пробное вычисление"

    # Сначала читаем HDFS напрямую, затем ту же учебную загрузку через Metastore.
    source = spark.read.text(f"{hdfs}/user/hive/warehouse/test.db/colours_staging")
    assert source.count() == 10, "В HDFS ожидалось 10 строк из ДЗ3"

    colours = spark.table("test.colours")
    colours.orderBy("colour").show()
    assert colours.count() == 10, "В test.colours ожидалось 10 строк из ДЗ3"
    print("Проверка YARN, HDFS и Hive Metastore пройдена")
finally:
    spark.stop()
