if [ "$(whoami)" != "hadoop" ]; then
    echo "Запускайте под пользователем hadoop: sudo -i -u hadoop" >&2
    exit 1
fi

source ../hw1/cluster.conf
source ../hw3/cluster.conf

export NAMENODE_HOST

export EDGE_IP=10.33.0.10

export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/home/hadoop/hadoop-3.4.0

export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HDFS_URL=hdfs://$NAMENODE_IP:9000

export HW4_RUNTIME=/home/hadoop/hw4-spark
export SPARK_HOME=$HW4_RUNTIME/spark-3.5.9-bin-hadoop3

export PYTHONPATH=$SPARK_HOME/python:$(ls "$SPARK_HOME"/python/lib/py4j-*-src.zip)
export PYSPARK_PYTHON=./python-env/python/bin/python3.11



export METASTORE_LOCAL_PORT=19083
export HIVE_HOME_ON_NN=/home/hadoop/apache-hive-4.0.0-alpha-2-bin
export HIVE_JDBC=jdbc:hive2://$NAMENODE_IP:10000


export HW5_HOME=/home/hadoop/hw5-prefect
export HW5_VENV=$HW5_HOME/venv
export PREFECT_HOME=$HW5_HOME/prefect

export PREFECT_SERVER_API_HOST=127.0.0.1
export PREFECT_SERVER_API_PORT=4200

export PREFECT_API_URL=http://127.0.0.1:4200/api

export PREFECT_SERVER_ANALYTICS_ENABLED=false

export PATH=$HW5_VENV/bin:$HADOOP_HOME/bin:$SPARK_HOME/bin:$PATH
