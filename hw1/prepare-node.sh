#!/usr/bin/env bash
set -euo pipefail
sudo -n apt-get update
sudo -n apt-get install -y openjdk-11-jdk-headless wget ca-certificates
# Пароль задаёт deploy-hdfs.sh через passwd сразу после подготовки этого узла.
sudo -n adduser --disabled-password --gecos '' hadoop
sudo -n -H -u hadoop mkdir -p /home/hadoop/.ssh /home/hadoop/hdfs-hw01/run
sudo -n -H -u hadoop chmod 700 /home/hadoop/.ssh
sudo -n -H -u hadoop chmod 750 /home/hadoop/hdfs-hw01 /home/hadoop/hdfs-hw01/run
