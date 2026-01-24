# V2

> 利用ConfigMap和Secret部署简单的Mysql+Wordpress

## env

集群已部署openelb和nfs动态置备

## sc

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  #server: nfs-server.default.svc.cluster.local
  server: nfs-server.nfs.svc.cluster.local
  #server: nfs.magedu.com
  share: /
  #share: /data
reclaimPolicy: Delete
volumeBindingMode: Immediate
#mountOptions:
#  - hard
#  - nfsvers=4.1
```







## mysql

secret-mysql

```yaml
root@master1:/test/test/works# cat mysql-secret.yaml 
apiVersion: v1
data:
  WORDPRESS_DB_HOST: bXlzcWwtc3Zj
  WORDPRESS_DB_NAME: d29yZHByZXNz
  WORDPRESS_DB_PASSWORD: d2Vpb3dvdw==
  WORDPRESS_DB_USER: d2VpeHg=
kind: Secret
metadata:
  creationTimestamp: null
  name: mysql-secret
```



```
 echo d2Vpb3dvdw== | base64 -d
```

pvc-mysql.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs-mysql
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-csi
```



mysql-server.yaml

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: mysql
  labels:
    app: mysql
spec:
  containers:
  - name: mysql
    image: docker.m.daocloud.io/library/mysql:8.0
    env:
    - name: MYSQL_ROOT_PASSWORD
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_PASSWORD
    - name: MYSQL_DATABASE
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_NAME
    - name: MYSQL_USER
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_USER
    - name: MYSQL_PASSWORD
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_PASSWORD
    volumeMounts: 
    - mountPath: /var/lib/mysql
      name: mysqldata
  volumes:
    - name: mysqldata
      persistentVolumeClaim:
        claimName: pvc-nfs-mysql
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: mysql-svc
  name: mysql-svc
spec:
  ports:
  - name: 3306-3306
    port: 3306
    protocol: TCP
    targetPort: 3306
  selector:
    app: mysql
  type: ClusterIP
```



## wordpress

pvc-wordpress.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: 
  name: wordpress-pvc
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-csi
```

wordpress.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs-mysql
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-csi
root@master1:/test/test/works# cat pvc-wordpress.yaml 
apiVersion: v1
kind: PersistentVolumeClaim
metadata: 
  name: wordpress-pvc
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-csi
root@master1:/test/test/works# cat wordpress.yaml 
---
apiVersion: v1
kind: Pod
metadata:
  name: wordpress
  labels:
    app: wp
spec:
  containers:
  - name: wordpress
    image: docker.m.daocloud.io/wordpress:php8.1-apache
    imagePullPolicy: IfNotPresent
    readinessProbe:
      httpGet:
        path: '/'
        port: 80
        scheme: HTTP
      initialDelaySeconds: 60
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 3
    env:
    - name: WORDPRESS_DB_HOST
      value: mysql-svc
    - name: WORDPRESS_DB_USER
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_USER
    - name: WORDPRESS_DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_PASSWORD
    - name: WORDPRESS_DB_NAME
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: WORDPRESS_DB_NAME
    volumeMounts:
    - name: data
      mountPath: /var/www/html/
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: wordpress-pvc
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: wordpress
  name: wordpress
  annotations:
    lb.kubesphere.io/v1alpha1: openelb
spec:
  ports:
  - name: 80-80
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: wp
  type: LoadBalancer
```



# V2

> mysql用statefulSet部署在集群中(主从分离)，然后部署proxysql实现mysql的读写分离，最后利用nginx作wordpress的反向代理

## 前提环境

openelb+nfs动态制备

## 部署mysql（statefulSet）

configmap-msyql.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-config
data:
  master.cnf: |
    [mysqld]
    log-bin
    server-id=1
  slave.cnf: |
    [mysqld]
    server-id=2  # Slave 的 ID 会在启动脚本中动态修改
```

secret-mysqlt.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
type: Opaque
data:
  # 123456 的 Base64 编码是 MTIzNDU2
  root-password: MTIzNDU2
```

statefulSet-mysql.yaml

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  selector:
    matchLabels:
      app: mysql
  serviceName: mysql-headless # 必须是 Headless Service
  replicas: 3
  template:
    metadata:
      labels:
        app: mysql
    spec:
      securityContext:
        fsGroup: 999
      initContainers:
      - name: init-mysql
        image: docker.m.daocloud.io/mysql:8.0
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name  # 这会把 "mysql-0" 注入环境变量
        command:
        - bash
        - "-c"
        - |
          set -ex
          # 改用环境变量 POD_NAME，不再调用 hostname 命令
          [[ $POD_NAME =~ -([0-9]+)$ ]] || exit 1
          ordinal=${BASH_REMATCH[1]}
          if [[ $ordinal -eq 0 ]]; then
            cp /mnt/config-map/master.cnf /etc/mysql/conf.d/
          else
            cp /mnt/config-map/slave.cnf /etc/mysql/conf.d/
            sed -i "s/server-id=2/server-id=$((2 + $ordinal))/" /etc/mysql/conf.d/slave.cnf
          fi
        volumeMounts:
        - name: conf
          mountPath: /etc/mysql/conf.d
        - name: config-map
          mountPath: /mnt/config-map
      containers:
      - name: mysql
        image: docker.m.daocloud.io/mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        - name: conf
          mountPath: /etc/mysql/conf.d
      volumes:
      - name: conf
        emptyDir: {}
      - name: config-map
        configMap:
          name: mysql-config
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: nfs-csi # 使用你的 NFS 存储
      resources:
        requests:
          storage: 10Gi
```

(注：MySQL 官方镜像要求数据目录 `/var/lib/mysql` 的所有者必须是 `mysql` 用户（UID 999），而nfs只有所有者可以写，所有者默认为root，所以要将所有者改为999)

svc-mysql.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless # 必须和 StatefulSet 里的 serviceName 一致
spec:
  clusterIP: None      # 关键！这就是 Headless 的标志
  selector:
    app: mysql
  ports:
  - port: 3306
    name: mysql
```

依次执行：

```sh
kubectl apply -f configmap-msyql.yaml
kubectl apply -f secret-mysqlt.yaml
kubectl apply -f statefulSet-mysql.yaml
kubectl apply -f svc-mysql.yaml
```

查看相关pvc和pv：

```sh
# kubectl get pvc,pv
NAME                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/data-mysql-0   Bound    pvc-a3b02562-81f3-4bda-96e5-151d85bca1d3   10Gi       RWO            nfs-csi        88m
persistentvolumeclaim/data-mysql-1   Bound    pvc-262d414b-8d37-4d38-b687-5a333fa4b48e   10Gi       RWO            nfs-csi        88m
persistentvolumeclaim/data-mysql-2   Bound    pvc-2c4aa96b-eca8-4208-86dc-b25cdb931194   10Gi       RWO            nfs-csi        88m
persistentvolumeclaim/wp-pvc         Bound    pvc-e45b4f67-8b87-46e8-abee-e357f428f5e5   5Gi        RWX            nfs-csi        48m

NAME                                                        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                  STORAGECLASS   REASON   AGE
persistentvolume/pvc-262d414b-8d37-4d38-b687-5a333fa4b48e   10Gi       RWO            Delete           Bound    default/data-mysql-1   nfs-csi                 88m
persistentvolume/pvc-2c4aa96b-eca8-4208-86dc-b25cdb931194   10Gi       RWO            Delete           Bound    default/data-mysql-2   nfs-csi                 88m
persistentvolume/pvc-a3b02562-81f3-4bda-96e5-151d85bca1d3   10Gi       RWO            Delete           Bound    default/data-mysql-0   nfs-csi                 88m
```

查看相关pod：

```sh
# kubectl get pods
NAME                           READY   STATUS    RESTARTS   AGE
mysql-0                        1/1     Running   0          70m
mysql-1                        1/1     Running   0          70m
mysql-2                        1/1     Running   0          70m
```

查看相关svc：

```sh
# kubectl get endpoints mysql-headless
NAME             ENDPOINTS                                            AGE
mysql-headless   10.244.1.29:3306,10.244.2.62:3306,10.244.3.89:3306   68m
```

在开始同步之前，先验证一下你的 `sed` 脚本是否真的给它们分配了不同的 `server-id`：:

```sh
# 查看 mysql-0 的 ID (应该是 1)
kubectl exec mysql-0 -- mysql -u root -p123456 -e "show variables like 'server_id';"

# 查看 mysql-1 的 ID (应该是 3)
kubectl exec mysql-1 -- mysql -u root -p123456 -e "show variables like 'server_id';"

# 查看 mysql-2 的 ID (应该是 4)
kubectl exec mysql-2 -- mysql -u root -p123456 -e "show variables like 'server_id';"
```



## 配置主从分离

> 主

```
kubectl exec -it mysql-0 -- mysql -u root -p123456
```

```sql
-- 创建一个专门用于同步的用户 repl
mysql> CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY '123456';
Query OK, 0 rows affected (0.02 sec)

mysql> GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
Query OK, 0 rows affected (0.00 sec)

mysql> FLUSH PRIVILEGES;
Query OK, 0 rows affected (0.00 sec)

-- 查看当前 Binlog 状态（非常重要，记下 File 和 Position）
mysql> SHOW MASTER STATUS;
+--------------------+----------+--------------+------------------+-------------------+
| File               | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set |
+--------------------+----------+--------------+------------------+-------------------+
| mysql-0-bin.000003 |      827 |              |                  |                   |
+--------------------+----------+--------------+------------------+-------------------+
1 row in set (0.00 sec)
```

> 从(执行两次,分别是1和2)

```
kubectl exec -it mysql-1 -- mysql -u root -p123456
```

```sql
CHANGE MASTER TO 
  MASTER_HOST='mysql-0.mysql-headless.default.svc.cluster.local',
  MASTER_USER='repl',
  MASTER_PASSWORD='123456',
  MASTER_LOG_FILE='mysql-0-bin.000003', -- 填刚才查到的File
  MASTER_LOG_POS=827; -- 填刚才查到的Position
START SLAVE;

-- 查看状态
SHOW SLAVE STATUS\G;
-- Slave_IO_Running	Yes	IO 线程正常：负责从主库读取 Binlog 并写入中继日志。
-- Slave_SQL_Running	Yes	SQL 线程正常：负责解析中继日志并执行 SQL 到本地
-- Seconds_Behind_Master	0	同步延迟：数值越小表示同步越实时。0 表示完全同步
```



## 部署proxysql实现msyql集群的读写分离

> 部署其工作信负载均衡器deployment和svc

proxySql.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: proxysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: proxysql
  template:
    metadata:
      labels:
        app: proxysql
    spec:
      containers:
      - name: proxysql
        image: docker.m.daocloud.io/proxysql/proxysql:3.0.5
        ports:
        - containerPort: 6033 # SQL 服务端口（应用连这里）
        - containerPort: 6032 # 管理端口（配置连这里）
---
apiVersion: v1
kind: Service
metadata:
  name: proxysql-svc
spec:
  selector:
    app: proxysql
  ports:
  - name: sql
    port: 6033
  - name: admin
    port: 6032
```

```
kubectl apply -f proxySql.yaml
```

查看pod状态

```sh
kubectl get pods -l app=proxysql
```

查看其svc状态

```sh
kubectl get endpoints proxysql-svc
```

> 配置读写分离

① 登录管理后台

默认账号密码是 `admin/admin`：

```sh
kubectl exec -it $(kubectl get pod -l app=proxysql -o jsonpath='{.items[0].metadata.name}') -- mysql -u admin -padmin -h 127.0.0.1 -P 6032
```

② 定义后端数据库（Hostgroups）

将 Master 划分为 **Group 10**，Slave 划分为 **Group 20**。

```sql
-- 添加主库 (mysql-0)
INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (10, 'mysql-0.mysql-headless', 3306);

-- 添加从库 (mysql-1, mysql-2)
INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (20, 'mysql-1.mysql-headless', 3306);
INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (20, 'mysql-2.mysql-headless', 3306);

-- 将配置加载到运行环境
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
```

③ 设置读写分离规则（Query Rules）

这是最核心的一步：通过正则表达式识别 SQL 语句。

```sql
-- 1. 强制所有 SELECT 语句走 20 号从库组
INSERT INTO mysql_query_rules(rule_id, active, match_digest, destination_hostgroup, apply)
VALUES (1, 1, '^SELECT.*', 20, 1);

-- 2. 特殊情况：SELECT FOR UPDATE 必须走 10 号主库组（权重更高）
INSERT INTO mysql_query_rules(rule_id, active, match_digest, destination_hostgroup, apply)
VALUES (2, 1, '^SELECT.*FOR UPDATE$', 10, 1);

-- 注意：所有非 SELECT 语句（INSERT/UPDATE）默认会走剩下的组，或者你可以显式定义。
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

> 配置应用访问账户:ProxySQL 需要知道哪些用户允许通过它连接数据库

```sql
-- 在 ProxySQL 中添加你的 mysql-secret 里的用户（比如 root）
INSERT INTO mysql_users(username, password, default_hostgroup) VALUES ('root', '123456', 10);

LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
```



## 部署wordpress

> mysql创建wordpress库

```sh
kubectl exec -it mysql-0 -- mysql -u root -p123456 -e "CREATE DATABASE IF NOT EXISTS wordpress;"
```

> 部署wordpress

pvc-wordpress.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wp-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 5Gi
```

deployment-wordpress.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
spec:
  replicas: 2 # 部署两个副本实现高可用
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: docker.m.daocloud.io/wordpress:php8.1-apache
        ports:
        - containerPort: 80
        env:
        - name: WORDPRESS_DB_HOST
          value: "proxysql-svc:6033"  # 重点：连 ProxySQL 而不是直连 MySQL
        - name: WORDPRESS_DB_USER
          value: "root"               # 对应你之前在 ProxySQL 里的配置
        - name: WORDPRESS_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: WORDPRESS_DB_NAME
          value: "wordpress"
        volumeMounts:
        - name: wp-data
          mountPath: /var/www/html
      volumes:
      - name: wp-data
        persistentVolumeClaim:
          claimName: wp-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: wordpress-svc
spec:
  selector:
    app: wordpress
  ports:
  - port: 80
    targetPort: 80
```

```sh
kubectl apply -f pvc-wordpress.yaml
kubectl apply -f deployment-wordpress.yaml
```

检查其pvc

```
kubectl get pv | grep wp-pvc
```

检查svc

```sh
# # kubectl get svc | grep wordpress-svc 
wordpress-svc    ClusterIP      10.111.57.45     <none>        80/TCP              62m

# kubectl get endpoints wordpress-svc
NAME            ENDPOINTS                       AGE
wordpress-svc   10.244.1.31:80,10.244.2.63:80   60m
```

检查pods

```sh
# kubectl get pods -l app=wordpress
NAME                         READY   STATUS    RESTARTS   AGE
wordpress-7b74b455cd-lwq4p   1/1     Running   0          61m
wordpress-7b74b455cd-ndqdj   1/1     Running   0          61m
```

测试wordpress是否正常

```sh
# curl -I 10.111.57.45
HTTP/1.1 302 Found
Server: nginx/1.28.1
Date: Sat, 24 Jan 2026 11:55:25 GMT
Content-Type: text/html; charset=UTF-8
Connection: keep-alive
X-Powered-By: PHP/8.1.34
Expires: Wed, 11 Jan 1984 05:00:00 GMT
Cache-Control: no-cache, must-revalidate, max-age=0, no-store, private
X-Redirect-By: WordPress
Location: http://10.0.0.141/wp-admin/install.php
```

## 部署nginx实现对wordpress的反向代理

configMap-nginx.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  default.conf: |
    upstream wordpress_backend {
        server wordpress-svc:80; # 指向 WordPress 的 Service 名字
    }

    server {
        listen 80;
        server_name _;

        # 增加上传限制，否则 WordPress 上传大图会报 413
        client_max_body_size 64M;

        location / {
            proxy_pass http://wordpress_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # 解决 WordPress 登录后的重定向循环问题
            proxy_redirect off;
        }

        # 缓存静态资源（可选，提升速度）
        location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
            proxy_pass http://wordpress_backend;
            expires max;
            log_not_found off;
        }
    }
```

deployment+svc-nginx.yaml 

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-entry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-entry
  template:
    metadata:
      labels:
        app: nginx-entry
    spec:
      containers:
      - name: nginx
        image: docker.m.daocloud.io/nginx:stable-alpine3.23
        ports:
        - containerPort: 80
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/conf.d # 覆盖掉默认配置
      volumes:
      - name: config
        configMap:
          name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-lb-svc
  annotations:
    # 核心：指定使用 OpenELB
    lb.kubesphere.io/v1alpha1: openelb
spec:
  type: LoadBalancer
  selector:
    app: nginx-entry
  ports:
  - name: http
    port: 80
    targetPort: 80
```

检查svc

````sh
# kubectl get svc | grep nginx-lb-svc
nginx-lb-svc     LoadBalancer   10.105.153.201   10.0.0.141    80:30783/TCP        65m
````

检查pods

```sh
kubectl get pods -l app=nginx-entry
```

浏览器访问wordpress

![image-20260124205309835](部署wordpress.assets/image-20260124205309835.png)

## 测试读写分离

进入 ProxySQL 管理端

```sh
kubectl exec -it $(kubectl get pod -l app=proxysql -o jsonpath='{.items[0].metadata.name}') -- mysql -u admin -padmin -h 127.0.0.1 -P 6032
```

观察

```
SELECT hostgroup, srv_host, Queries FROM stats_mysql_connection_pool;
```





















```sql

```



