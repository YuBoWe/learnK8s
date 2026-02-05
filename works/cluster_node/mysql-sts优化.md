# 发现问题
worker2+2明显内存不足，用statefulset跑，3个mysql要占1.5g的内存，一个将近500多，很容易把内存挤爆，导致kubelet失灵

# 解决
MySQL 资源限制与反亲和性备份 (StatefulSet)
这是解决 Worker1 内存 84% 问题的核心配置。
```yaml
# 备份路径建议: ~/learnK8s/backup/mysql-sts-optimized.yaml
# 关键提取：
resources:
  requests:
    cpu: "100m"
    memory: "400Mi"
  limits:
    cpu: "500m"
    memory: "700Mi"
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: mysql
      topologyKey: "kubernetes.io/hostname"
```
MySQL 内存参数优化备份 (ConfigMap)
这是让 MySQL 在 2GB 小内存机器上稳定运行的内部配置。
```yaml
# 关键提取：
[mysqld]
innodb_buffer_pool_size=256M
innodb_log_buffer_size=16M
max_connections=100
```
