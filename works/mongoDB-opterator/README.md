# 云原生 MongoDB 副本集部署方案 (Operator + NFS + OpenELB)

本项目在 Kubernetes 环境下实现了生产级的 MongoDB 异步副本集部署。通过 Operator 模式实现数据库全生命周期管理，结合容器化 NFS 实现持久化，并利用 OpenELB 解决了裸机 K8s 环境下的 LoadBalancer 接入难题。

## 🏗 架构组成

- **数据库控制层**：`MongoDB Community Operator (v1.6.1)` —— 负责副本集选举、状态同步及自动运维。
- **存储层**：`Containerized NFS Server` + `NFS-CSI Driver` —— 提供动态申请的持久化存储卷。
- **网络接入层**：`OpenELB (Layer2 模式)` —— 宣告 ARP 并分配 VIP `10.0.0.143` 实现外部接入。
- **部署空间**：统一在 `mongodb` 命名空间下完成管控，实现管理面与数据面逻辑隔离。

------

## 🛠 部署步骤

### 1. 存储环境准备 (NFS)

基于容器化的 NFS 服务器提供存储支持，底层数据映射至宿主机磁盘，确保 Pod 漂移后数据不丢失。

- **StorageClass 名称**: `openebs-hostpath`

### 2. 部署 MongoDB Operator

安装 CRD 资源定义与控制器：

Bash

```
# 1. 安装核心自定义资源定义 (CRD)
kubectl apply -f https://raw.githubusercontent.com/mongodb/mongodb-kubernetes/1.6.1/deploy/crds/mongodb.com_mongodbcommunities_crd.yaml

# 2. 安装 Operator 控制器
kubectl apply -f https://raw.githubusercontent.com/mongodb/mongodb-kubernetes/1.6.1/deploy/operator/mongodb-operator.yaml -n mongodb
```

> **⚠️ 关键补丁**：必须修改 Operator Deployment，将环境变量 `WATCH_NAMESPACE` 设为 `""`，否则控制器无法感知跨命名空间的资源请求。

### 3. 定义 MongoDB 副本集实例 (`mongo-instance.yaml`)

YAML

```
piVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: ops-mongo
  namespace: mongodb
spec:
  members: 3
  type: ReplicaSet
  version: "6.0.5"
  replicaSetHorizons:
    - external: "mongo-0-lb.local:27017"
    - external: "mongo-1-lb.local:27017"
    - external: "mongo-2-lb.local:27017"

  security:
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
  statefulSet:
    spec:
      template:
        spec:
          initContainers:
            - name: check-and-fix-permissions
              image: docker.m.daocloud.io/busybox:1.37.0
              command: ["sh", "-c", "chown -R 999:999 /data && chown -R 999:999 /var/log/mongodb-mms-automation"]
              securityContext:
                runAsUser: 0 # 只有 root 才有权限 chown
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
              resources:
                limits:
                  cpu: "500m"
                  memory: "1Gi"
                requests:
                  cpu: "200m"
                  memory: "512Mi"
      # --- 修正后的存储模板 ---
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
            name: logs-volume # 必须加上这个，否则会自动使用默认SC导致挂起
          spec:
            storageClassName: openebs-hostpath
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi # 日志不需要太大
---
# 1. 对应 ops-mongo-0 (端口 27017)
apiVersion: v1
kind: Service
metadata:
  name: mongo-ext-0
  namespace: mongodb
  annotations:
    lb.kubesphere.io/v1alpha1: openelb
    protocol.openelb.kubesphere.io/v1alpha1: tcp
    # 如果你想固定 IP 为 10.0.0.141，取消下面注释 (前提是 OpenELB 配置允许)
    # eip.openelb.kubesphere.io/v1alpha1: 10.0.0.141
spec:
  type: LoadBalancer
  selector:
    statefulset.kubernetes.io/pod-name: ops-mongo-0
  ports:
    - name: mongodb
      protocol: TCP
      port: 27017
      targetPort: 27017

---
# 2. 对应 ops-mongo-1 (端口 27018)
apiVersion: v1
kind: Service
metadata:
  name: mongo-ext-1
  namespace: mongodb
  annotations:
    lb.kubesphere.io/v1alpha1: openelb
spec:
  type: LoadBalancer
  selector:
    statefulset.kubernetes.io/pod-name: ops-mongo-1
  ports:
    - name: mongodb
      protocol: TCP
      port: 27017 # 外部端口
      targetPort: 27017 # 容器内部始终是 27017

---
# 3. 对应 ops-mongo-2 (端口 27019)
apiVersion: v1
kind: Service
metadata:
  name: mongo-ext-2
  namespace: mongodb
  annotations:
    lb.kubesphere.io/v1alpha1: openelb
spec:
  type: LoadBalancer
  selector:
    statefulset.kubernetes.io/pod-name: ops-mongo-2
  ports:
    - name: mongodb
      protocol: TCP
      port: 27017 # 外部端口
      targetPort: 27017
```
> 由于需要对接集群外部的连接，所以这里开启horizon split，并配置了三个lb，直接功能是外部访问时，会询问集群哪个是primary节点（只有primary节点可写），然后通过给的horizon的配置的域名或者ip直接返回，但是来的时候经过了openelb，mongodb将其识别为集群内部流量，返回的时候会按照集群内部的svc来返回，我的解决方案就是利用集群外部的DNS将集群内部的域名加上去。

### 4. 外部接入配置 (OpenELB)

创建物理层 Service，将外部流量通过 VIP 导向副本集：

YAML

```
apiVersion: v1
kind: Service
metadata:
  name: mongo-external
  namespace: mongodb
  annotations:
    lb.kubesphere.io/v1alpha1: openelb # 触发 OpenELB 分配 IP
spec:
  selector:
    app: ops-mongo-svc # 必须与 Operator 生成的 Pod Label 严格对齐
  type: LoadBalancer
  ports:
    - protocol: TCP
      port: 27017
      targetPort: 27017
```

------

## 🔍 故障排查手册 (面试核心)

| 故障现象                  | 根源分析                                                     | 解决方案                                                     |
| ------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **Pod 无法创建**          | `WATCH_NAMESPACE` 环境变量被限制在单空间，导致控制器无法监听到实例声明。 | 修改 Deployment 设置 `WATCH_NAMESPACE: ""`，开启 Cluster-wide 监听。 |
| **Endpoints 为 `<none>`** | 手动创建的 Service 选择器 (`Selector`) 与 Operator 自动生成的 Pod 标签不匹配。 | 使用 `kubectl get pods --show-labels` 反查标签，并更新 Service 的 Selector 字段。 |
| **客户端连接 DNS 报错**   | 副本集协议默认返回 K8s 内部 FQDN (`.cluster.local`)，外部客户端无法解析。 | 在连接串中显式增加 `directConnection=true` 参数，绕过副本集成员自动发现机制。 |

Export to Sheets

------

## 💾 备份与迁移策略

1. **逻辑备份 (mongodump)**: 通过 OpenELB 分配的 VIP 执行全量导出。 `mongodump --host 10.0.0.143 -u admin -p <pass> --out ./backup/`
2. **物理迁移 (kubectl cp)**: 由于 NFS 服务器运行在集群内，可利用 `kubectl cp` 直接从 NFS Pod 导出原始数据文件，实现跨集群的冷迁移。

------

## 📈 项目亮点总结

- **全生命周期自动化**: 通过 Operator 实现数据库的声明式管理，极大降低了运维复杂度。
- **自愈性保障**: 结合 StatefulSet 与 NFS-CSI，确保 Pod 故障后能自动拉起并重新挂载原有数据。
- **裸机环境适配**: 利用 OpenELB 成功在物理网络中实现了 LoadBalancer 功能，解决了外部直连容器服务的痛点。
