CREATE DATABASE IF NOT EXISTS test;
USE test;

CREATE TABLE IF NOT EXISTS colours (
  number int
)
PARTITIONED BY (colour string)
COMMENT 'colours table (partitioned by colour)'
ROW FORMAT DELIMITED
FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE;

LOAD DATA INPATH '/input/hw03/colours/red/data.tsv' INTO TABLE colours PARTITION (colour='red');
LOAD DATA INPATH '/input/hw03/colours/blue/data.tsv' INTO TABLE colours PARTITION (colour='blue');
