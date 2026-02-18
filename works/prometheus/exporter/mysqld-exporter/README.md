## 下载mysqld-exporter镜像
```sh
ctr -n k8s.io images pull docker.m.daocloud.io/prom/mysqld-exporter:v0.18.0
```

## mysql主节点创建监控所用的用户
```sql
-- 创建监控专用用户（注意：如果是 8.0+ 版本，语法必须分开写）
CREATE USER 'exporter'@'%' IDENTIFIED BY '123456' WITH MAX_USER_CONNECTIONS 3;

-- 授予必要的监控权限
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';

-- 刷新权限
FLUSH PRIVILEGES;
```

## 部署secret和deployment
```
kubectl apply -f secret-exporter-auth.yaml
kubectl apply -f deployment-exporter.yaml
```

## 监控的相关指标
```
1. 核心状态类

    --collect.global_status

        作用：这是最基础、最重要的。它对应 MySQL 的 SHOW GLOBAL STATUS。

        监控内容：连接数（Connections）、查询次数（Queries）、慢查询数（Slow_queries）、运行时间（Uptime）等。没有它，监控就失去了灵魂。

    --collect.slave_status

        作用：监控主从复制情况。

        监控内容：最核心的是 seconds_behind_master（从库延迟时间）。如果是 0，说明同步实时；如果是几百，说明从库追不上主库了。

2. InnoDB 存储引擎类（数据库的“心脏”）

    --collect.info_schema.innodb_metrics

        作用：从 information_schema 获取更细粒度的 InnoDB 内部指标。

        监控内容：缓冲池（Buffer Pool）的使用率、脏页数量、事务的回滚和提交情况。

    --collect.engine_innodb_status

        作用：对应 SHOW ENGINE INNODB STATUS。

        监控内容：主要是死锁（Deadlocks）和行锁等待。通过这个能发现是不是有某些 SQL 把表锁死了。

    --collect.info_schema.innodb_tablespaces

        作用：监控表空间信息。

        监控内容：表文件的实际大小、剩余空间等。防止磁盘空间被某个大表突然撑爆。

3. 日志与内存类

    --collect.binlog_size

        作用：统计二进制日志（Binlog）的总大小。

        监控内容：磁盘占用。如果 Binlog 增长极快，说明最近有大量的写操作（或者删表操作），需要注意磁盘报警。

    --collect.perf_schema.memory_events

        作用：从 performance_schema 监控内存分配。

        监控内容：MySQL 内部各个组件（比如排序缓冲区、连接缓冲区）占用了多少内存。对于排查 MySQL 内存泄漏 或 OOM（内存溢出） 非常管用。

4. 性能分析类

    --collect.perf_schema.eventsstatements

        作用：统计各类 SQL 语句的执行情况。

        监控内容：哪类 SQL 最耗时？哪类 SQL 报错最多？它能把 SELECT、INSERT、UPDATE 分开统计执行延迟。
```
