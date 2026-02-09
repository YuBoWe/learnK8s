# MongoDB 副本集部署指南 

## 1. 第一步：本地生成 TLS 证书 (OpenSSL)

在集群外部执行以下步骤生成所需的证书文件。

### 1.1 生成根证书 (CA)

```Bash
# 生成 CA 私钥
openssl genrsa -out ca.key 2048

# 生成自签名根证书
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=mongodb-ca" -out ca.crt
```

### 1.2 生成服务器证书 (Server Certificate)

创建 `openssl.cnf` 以包含所有 K8s 内部域名和外部 IP

```plsql
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ops-mongo
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = ops-mongo-0.ops-mongo-svc.mongodb.svc.cluster.local
DNS.3 = ops-mongo-1.ops-mongo-svc.mongodb.svc.cluster.local
DNS.4 = ops-mongo-2.ops-mongo-svc.mongodb.svc.cluster.local
DNS.5 = *.ops-mongo-svc.mongodb.svc.cluster.local
IP.1 = 127.0.0.1
```

执行签名：

```bash
# 生成服务器私钥
openssl genrsa -out server.key 2048

# 生成签名请求 (CSR)
openssl req -new -key server.key -out server.csr -config openssl.cnf

# 使用 CA 签署服务器证书
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -extensions v3_req -extfile openssl.cnf
```

### 1.3 合成三合一 PEM 文件

MongoDB Agent 要求提供一个包含私钥和完整证书链的文件。

```bash
cat server.key server.crt ca.crt > tls.pem
```

------

## 2. 第二步：生成 Kubernetes Secret YAML

使用 `--dry-run=client -o yaml` 生成 Secret 定义文件，方便存入 Git。

### 2.1 生成管理员密码 Secret

```sh
kubectl create secret generic mongo-admin-pw \
  --from-literal=password='123456' \
  -n mongodb --dry-run=client -o yaml > mongo-password.yaml
```

### 2.2 生成 CA 证书 Secret

```sh
kubectl create secret generic ops-mongo-ca \
  --from-file=ca.crt=ca.crt \
  -n mongodb --dry-run=client -o yaml > mongo-ca-secret.yaml
```

### 2.3 生成证书链 Secret (tls.pem)

Bash

```sh
kubectl create secret generic ops-mongo-cert \
  --from-file=tls.pem=tls.pem \
  -n mongodb --dry-run=client -o yaml > mongo-cert-secret.yaml
```

------

## 3. 第三步：MongoDB 主资源清单 (`mongodb-rs.yaml`)

这是最终的核心资源定义。

```yaml
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: ops-mongo
  namespace: mongodb
spec:
  members: 3
  type: ReplicaSet
  version: "6.0.5"
  security:
    tls:
      certificateKeySecretRef:
        name: ops-mongo-cert
      caCertificateSecretRef:
        name: ops-mongo-ca
      enabled: true
    authentication:
      modes: ["SCRAM"]
  users:
    - name: admin
      db: admin
      passwordSecretRef:
        name: mongo-admin-pw
      roles:
        - name: clusterAdmin
          db: admin
        - name: userAdminAnyDatabase
          db: admin
        - name: readWriteAnyDatabase
          db: admin
      scramCredentialsSecretName: ops-mongo-scram

  # --- 核心修改区：所有资源配置必须包裹在 statefulSet.spec 之下 ---
  statefulSet:
    spec:
      # 1. 存储卷定义 (必须移到这里，否则报 unknown field)
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            storageClassName: openebs-hostpath
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 10Gi
        - metadata:
            name: logs-volume
          spec:
            storageClassName: openebs-hostpath
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi
      template:
        spec:
          initContainers:
            - name: check-and-fix-permissions
              image: docker.m.daocloud.io/busybox:1.37.0
              command: ["sh", "-c", "chown -R 999:999 /data && chown -R 999:999 /var/log/mongodb-mms-automation"]
              securityContext:
                runAsUser: 0
              volumeMounts:
                - name: data-volume
                  mountPath: /data
                - name: logs-volume
                  mountPath: /var/log/mongodb-mms-automation
          securityContext:
            fsGroup: 999
            runAsUser: 999
            runAsGroup: 999
          containers:
            - name: mongod
              volumeMounts:
                - name: data-volume
                  mountPath: /data
                - name: logs-volume
                  mountPath: /var/log/mongodb-mms-automation
              resources:
                limits:
                  cpu: "500m"
                  memory: "1Gi"
                requests:
                  cpu: "200m"
                  memory: "512Mi"
```

------

相关配置解释：

```
# tls
enabled: true: 强制开启 TLS。这意味着你不能再用普通的 mongodb:// 协议访问，必须在连接字符串里加上 ?tls=true。所有的流量都会被加密。

caCertificateSecretRef (根证书): 这是“信任的源头”。它告诉 MongoDB 容器：“只有用这个 CA 签发的证书，我才认。” 当你从外部连接时，你的客户端（如 Compass）也需要这个 CA 文件来验证服务器的身份。

certificateKeySecretRef (服务证书): 这是 MongoDB 节点自己持有的“身份证”。它包含了私钥和公钥证书。
```

```
#     authentication:
#      modes: ["SCRAM"]
配置 modes: ["SCRAM"] 意味着你开启了 MongoDB 最标准的 “用户名+密码” 认证机制（Salted Challenge Response Authentication Mechanism）。
什么是 SCRAM？
这是 MongoDB 默认的身份验证方式。当你连接时：
    客户端发送用户名。
    服务端返回一个“盐值 (Salt)”。
    客户端用密码哈希和盐值计算出一个响应。
    关键点：密码永远不会在网络上以明文传输。

```

```
#   users:
name: admin & db: admin:
    创建用户名为 admin。
    这个用户存储在 admin 数据库中（这是 MongoDB 存放管理级用户的标准地方）。
    
passwordSecretRef:
    关键安全机制：你不需要在 YAML 里明文写密码。
    它指向一个名为 mongo-admin-pw 的 K8S Secret。这个 Secret 里必须包含一个 password 字段。Operator 会自动读取它并设置给 MongoDB。
    
roles (角色/权限): 这里给 admin 用户分配了三个最高级别的权限，基本等同于“数据库根用户”：
    clusterAdmin: 允许管理整个集群（如查看分片、副本集状态）。
    userAdminAnyDatabase: 允许在任何数据库创建和修改用户。
    readWriteAnyDatabase: 允许对所有数据库进行读写。

scramCredentialsSecretName: ops-mongo-scram:
    这是 Operator 的一个持久化特性。
    当 MongoDB 使用 SCRAM 认证时，会生成一些哈希后的凭证。Operator 将这些计算好的凭证备份到这个 Secret 中。这样即使 Pod 重建或数据库重装，用户的认证信息也能快速恢复，不需要重新生成。
```

```
# init容器 解决权限
在 K8S 中，当你挂载外部存储（如 PVC/云盘）到 MongoDB 时，存储卷的初始所有者通常是 root (UID 0)。
但是，MongoDB 容器为了安全，通常以非特权用户 mongodb (UID 999) 的身份运行。如果 mongodb 用户尝试往 root 所有的文件夹里写数据，就会报错 Permission denied，导致数据库启动失败（CrashLoopBackOff）。
chown -R 999:999 的意思是：递归地将指定目录的所有者改为 UID 999。
/data: MongoDB 存放数据文件的路径。
/var/log/mongodb-mms-automation: MongoDB Automation Agent 存放日志的路径（Operator 依赖这个 Agent）。

securityContext: runAsUser: 0:
    这是关键：必须以 root 身份运行。只有 root 才有权限修改其他用户（比如刚挂载进来的 root 卷）的文件所有者。
    
volumeMounts:
    它挂载了和主容器相同的卷。只有挂载了这些卷，它才能对这些卷里的目录执行 chown 操作。

```

```
 # securityContext
 runAsUser: 999:
    强制容器内的进程以 UID 999 运行。
    在 MongoDB 官方镜像中，UID 999 预定义为 mongodb 用户。

runAsGroup: 999:
    强制进程以 GID 999 运行（即 mongodb 用户组）。

fsGroup: 999:
    这是一个非常重要的 K8S 特性。它告诉 K8S：“当挂载数据卷（PVC）时，请自动将该卷下所有文件的所属组改为 GID 999。”
    它能和你的 initContainers 形成双重保险，确保 MongoDB 对数据目录有读写权限。
    
# 为什么有了 initContainers 还要写这个
initContainers 里的 chown 命令和这里的 securityContext 其实是 “皮带加吊带” 的关系，共同解决存储权限问题：
InitContainer	启动前运行一次	物理修改磁盘文件所有者	彻底，能处理已存在的旧数据文件。
fsGroup	挂载卷时	逻辑修改卷访问权限	自动化，K8S 原生支持，不需要写复杂的脚本。
在 MongoDB Community Operator 的设计中，有些目录（如日志目录或特定的 Agent 运行目录）可能不是通过 PVC 挂载的，而是通过 emptyDir 或容器层生成的。fsGroup 只能作用于 volume 挂载点，而 initContainers 可以灵活地对容器内任何路径进行权限修复。
```





## 4. 部署与连接

### 4.1 应用所有文件

```sh
kubectl apply -f mongo-password.yaml
kubectl apply -f mongo-ca-secret.yaml
kubectl apply -f mongo-cert-secret.yaml
kubectl apply -f mongodb-rs.yaml
```

查看mdbc状态，如果running则为成功

```sh
kubectl get mdbc -n mongodb
```

如果mdbc一直pending，排错思路：

```sh
# 进入到集群任一的pod查看集群状态
kubectl exec -it ops-mongo-0 -n mongodb -c mongod -- mongosh "mongodb://admin:123456@localhost:27017/?authSource=admin" --tls --tlsAllowInvalidCertificates --tlsAllowInvalidHostnames
# 输入
rs.status()
```

正常状态：

```js
ops-mongo [direct: primary] test> rs.status()
{
  set: 'ops-mongo',
  date: ISODate('2026-02-09T05:58:48.625Z'),
  myState: 1,
  term: Long('1'),
  syncSourceHost: '',
  syncSourceId: -1,
  heartbeatIntervalMillis: Long('2000'),
  majorityVoteCount: 2,
  writeMajorityCount: 2,
  votingMembersCount: 3,
  writableVotingMembersCount: 3,
  optimes: {
    lastCommittedOpTime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
    lastCommittedWallTime: ISODate('2026-02-09T05:58:47.369Z'),
    readConcernMajorityOpTime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
    appliedOpTime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
    durableOpTime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
    lastAppliedWallTime: ISODate('2026-02-09T05:58:47.369Z'),
    lastDurableWallTime: ISODate('2026-02-09T05:58:47.369Z')
  },
  lastStableRecoveryTimestamp: Timestamp({ t: 1770616687, i: 1 }),
  electionCandidateMetrics: {
    lastElectionReason: 'electionTimeout',
    lastElectionDate: ISODate('2026-02-09T04:15:16.918Z'),
    electionTerm: Long('1'),
    lastCommittedOpTimeAtElection: { ts: Timestamp({ t: 1770610506, i: 1 }), t: Long('-1') },
    lastSeenOpTimeAtElection: { ts: Timestamp({ t: 1770610506, i: 1 }), t: Long('-1') },
    numVotesNeeded: 2,
    priorityAtElection: 1,
    electionTimeoutMillis: Long('10000'),
    numCatchUpOps: Long('0'),
    newTermStartDate: ISODate('2026-02-09T04:15:16.944Z'),
    wMajorityWriteAvailabilityDate: ISODate('2026-02-09T04:15:17.856Z')
  },
  members: [
    {
      _id: 0,
      name: 'ops-mongo-0.ops-mongo-svc.mongodb.svc.cluster.local:27017',
      health: 1,
      state: 1,
      stateStr: 'PRIMARY',
      uptime: 6338,
      optime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
      optimeDate: ISODate('2026-02-09T05:58:47.000Z'),
      lastAppliedWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      lastDurableWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      syncSourceHost: '',
      syncSourceId: -1,
      infoMessage: '',
      electionTime: Timestamp({ t: 1770610516, i: 1 }),
      electionDate: ISODate('2026-02-09T04:15:16.000Z'),
      configVersion: 1,
      configTerm: 1,
      self: true,
      lastHeartbeatMessage: ''
    },
    {
      _id: 1,
      name: 'ops-mongo-1.ops-mongo-svc.mongodb.svc.cluster.local:27017',
      health: 1,
      state: 2,
      stateStr: 'SECONDARY',
      uptime: 6221,
      optime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
      optimeDurable: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
      optimeDate: ISODate('2026-02-09T05:58:47.000Z'),
      optimeDurableDate: ISODate('2026-02-09T05:58:47.000Z'),
      lastAppliedWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      lastDurableWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      lastHeartbeat: ISODate('2026-02-09T05:58:48.346Z'),
      lastHeartbeatRecv: ISODate('2026-02-09T05:58:46.834Z'),
      pingMs: Long('0'),
      lastHeartbeatMessage: '',
      syncSourceHost: 'ops-mongo-0.ops-mongo-svc.mongodb.svc.cluster.local:27017',
      syncSourceId: 0,
      infoMessage: '',
      configVersion: 1,
      configTerm: 1
    },
    {
      _id: 2,
      name: 'ops-mongo-2.ops-mongo-svc.mongodb.svc.cluster.local:27017',
      health: 1,
      state: 2,
      stateStr: 'SECONDARY',
      uptime: 6221,
      optime: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
      optimeDurable: { ts: Timestamp({ t: 1770616727, i: 1 }), t: Long('1') },
      optimeDate: ISODate('2026-02-09T05:58:47.000Z'),
      optimeDurableDate: ISODate('2026-02-09T05:58:47.000Z'),
      lastAppliedWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      lastDurableWallTime: ISODate('2026-02-09T05:58:47.369Z'),
      lastHeartbeat: ISODate('2026-02-09T05:58:48.346Z'),
      lastHeartbeatRecv: ISODate('2026-02-09T05:58:46.805Z'),
      pingMs: Long('0'),
      lastHeartbeatMessage: '',
      syncSourceHost: 'ops-mongo-0.ops-mongo-svc.mongodb.svc.cluster.local:27017',
      syncSourceId: 0,
      infoMessage: '',
      configVersion: 1,
      configTerm: 1
    }
  ],
  ok: 1,
  '$clusterTime': {
    clusterTime: Timestamp({ t: 1770616727, i: 1 }),
    signature: {
      hash: Binary.createFromBase64('Hp49trMeFVc3EyKl9u3uXd4aqGI=', 0),
      keyId: Long('7604714260173684742')
    }
  },
  operationTime: Timestamp({ t: 1770616727, i: 1 })
}
```

查看operator容器日志：

````sh
kubectl logs mongodb-kubernetes-operator-679c97777-z6vn2 -n mongodb --tail=20
````



再看看集群pod日志：

```
kubectl logs ops-mongo-0 -n mongodb -c mongod --tail=100
```

```js
// 下面是我证书出问题的日志，可做参考
{"t":{"$date":"2026-02-09T04:01:13.870+00:00"},"s":"I",  "c":"NETWORK",  "id":22943,   "ctx":"listener","msg":"Connection accepted","attr":{"remote":"10.244.2.131:38762","uuid":"3aee7234-f13c-4fb7-8d03-76989a4384de","connectionId":4104,"connectionCount":18}}
{"t":{"$date":"2026-02-09T04:01:13.871+00:00"},"s":"W",  "c":"NETWORK",  "id":23234,   "ctx":"conn4104","msg":"No SSL certificate provided by peer"}
{"t":{"$date":"2026-02-09T04:01:13.871+00:00"},"s":"I",  "c":"NETWORK",  "id":51800,   "ctx":"conn4104","msg":"client metadata","attr":{"remote":"10.244.2.131:38762","client":"conn4104","doc":{"application":{"name":"MongoDB Automation Agent v108.0.2.8729 (git: ec1573c1fd5d7da3acab288d628b9e9eaaec6b2b)"},"driver":{"name":"mongo-go-driver","version":"v1.12.0-cloud"},"os":{"type":"linux","architecture":"arm64"},"platform":"go1.22.9"}}}
{"t":{"$date":"2026-02-09T04:01:13.874+00:00"},"s":"I",  "c":"ACCESS",   "id":20250,   "ctx":"conn4104","msg":"Authentication succeeded","attr":{"mechanism":"SCRAM-SHA-256","speculative":true,"principalName":"__system","authenticationDatabase":"local","remote":"10.244.2.131:38762","extraInfo":{}}}
{"t":{"$date":"2026-02-09T04:01:13.876+00:00"},"s":"I",  "c":"NETWORK",  "id":22944,   "ctx":"conn4103","msg":"Connection ended","attr":{"remote":"10.244.2.131:38752","uuid":"82063174-9512-4c24-ab62-fea42bb1940a","connectionId":4103,"connectionCount":17}}
{"t":{"$date":"2026-02-09T04:01:13.876+00:00"},"s":"I",  "c":"-",        "id":20883,   "ctx":"conn4102","msg":"Interrupted operation as its client disconnected","attr":{"opId":62630}}
{"t":{"$date":"2026-02-09T04:01:13.877+00:00"},"s":"I",  "c":"NETWORK",  "id":22944,   "ctx":"conn4102","msg":"Connection ended","attr":{"remote":"10.244.2.131:38740","uuid":"536f68e5-928b-4d85-941c-ed73e39083cd","connectionId":4102,"connectionCount":16}}
{"t":{"$date":"2026-02-09T04:01:13.877+00:00"},"s":"I",  "c":"NETWORK",  "id":22944,   "ctx":"conn4104","msg":"Connection ended","attr":{"remote":"10.244.2.131:38762","uuid":"3aee7234-f13c-4fb7-8d03-76989a4384de","connectionId":4104,"connectionCount":15}}
{"t":{"$date":"2026-02-09T04:01:14.385+00:00"},"s":"I",  "c":"CONNPOOL", "id":22576,   "ctx":"ReplNetwork","msg":"Connecting","attr":{"hostAndPort":"ops-mongo-1.ops-mongo-svc.mongodb.svc.cluster.local:27017"}}
{"t":{"$date":"2026-02-09T04:01:14.385+00:00"},"s":"I",  "c":"CONNPOOL", "id":22576,   "ctx":"ReplNetwork","msg":"Connecting","attr":{"hostAndPort":"ops-mongo-2.ops-mongo-svc.mongodb.svc.cluster.local:27017"}}
```

查看lb的地址

```sh
# kubectl get svc -n mongodb
NAME               TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)           AGE
mongo-ext-0        LoadBalancer   10.97.129.170    10.0.0.141    27017:32398/TCP   92m
mongo-ext-1        LoadBalancer   10.107.133.64    10.0.0.142    27017:30153/TCP   92m
mongo-ext-2        LoadBalancer   10.111.109.133   10.0.0.143    27017:32542/TCP   92m
operator-webhook   ClusterIP      10.107.23.231    <none>        443/TCP           7d1h
```



### 4.2 客户端 Hosts 配置

在连接 Compass 的机器上配置 `/etc/hosts`：

```plaintext
10.0.0.141 ops-mongo-0.ops-mongo-svc.mongodb.svc.cluster.local
10.0.0.142 ops-mongo-1.ops-mongo-svc.mongodb.svc.cluster.local
10.0.0.143 ops-mongo-2.ops-mongo-svc.mongodb.svc.cluster.local
```

### 4.3 验证命令

```Bash
# 生成检查状态的 YAML（仅预览）
kubectl get mdbc ops-mongo -n mongodb -o yaml
```

### 4.4 使用compass测试连接

```sh
mongodb://admin:123456@10.0.0.141:27017,10.0.0.142:27017,10.0.0.143:27017/?authSource=admin&replicaSet=ops-mongo&tls=true&tlsInsecure=true
```

