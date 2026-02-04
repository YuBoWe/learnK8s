# 🛠️ 实操记录：2GB 内存环境下的 K8s 资源调优

**日期**：2026-02-03

**环境**：VMware Mac + Ubuntu (2GB RAM) + Envoy Gateway + MongoDB Operator

------

### 第一阶段：网关迁移与 Master 节点加固

为了利用 Master 节点的空闲 CPU 并统一入口，我们执行了以下操作：

1. **修改 EnvoyProxy 配置**： 在 `EnvoyProxy` 的 YAML 中加入了 `tolerations`（容忍度）和 `nodeAffinity`（亲和性），确保网关 Pod 能够调度到带污点的 Master 节点。

   ```yaml
   kind: EnvoyProxy
   metadata:
     name: custom-proxy
     namespace: envoy-gateway-system
   spec:
     provider:
       type: Kubernetes
       kubernetes:
         # 控制 DaemonSet 的部署逻辑
         envoyDaemonSet:
           pod:
             # 1. 强制只调度到你打了标签的 Master 节点
             nodeSelector:
               gateway: "true"
             # 2. 关键修改：添加容忍度，允许 Pod 运行在 Master 节点上
             tolerations:
               - key: "node-role.kubernetes.io/control-plane"
                 operator: "Exists"
                 effect: "NoSchedule"
               - key: "node-role.kubernetes.io/master"
                 operator: "Exists"
                 effect: "NoSchedule"
           container:
             image: docker.m.daocloud.io/envoyproxy/envoy:v1.33.0
             resources:
               requests:
                 cpu: 100m
                 memory: 128Mi
               limits:
                 cpu: 500m
                 memory: 512Mi
         # Service 配置保持不变
         envoyService:
           type: LoadBalancer
           annotations:
             lb.kubesphere.io/v1alpha1: openelb
   ```

   

2. **应用配置并验证位置**：

   ```bash
   # 应用修改后的网关策略
   kubectl apply -f custom-proxy.yaml
   
   # 检查 Envoy 是否成功降落在 master2 上
   kubectl get pods -n envoy-gateway-system -o wide
   ```

3. **检查 Master 负载**：

   ```bash
   # 发现 master2 的内存极度紧张 (free 仅剩 60MB)
   top
   ```

------

### 第二阶段：MongoDB “瘦身”实操

发现 `master2` 内存不足是因为跑了 3 个 MongoDB 副本。我们通过 Operator 进行了强制减负：

1. **定位 MongoDB 资源**：

   ```bash
   # 确认由 Operator 管理的资源名称
   kubectl get mongodbcommunity -n mongodb
   # 输出结果：ops-mongo
   ```

2. **在线修改集群规模与配置**： 执行以下命令进入交互式编辑模式：

   ```Bash
   kubectl edit mongodbcommunity ops-mongo -n mongodb
   ```

   **我们在编辑器中实际修改了三处：**

   - 将 `members: 3` 改为 `members: 1`（删除多余副本）。
   - 在 `additionalMongodConfig` 下添加 `storage.wiredTiger.engineConfig.cacheSizeGB: 0.25`（强制限制内部缓存）。
   - 修改 `resources.limits.memory` 为 `768Mi`（防止 OOM 杀掉系统进程）。

3. **监控 Operator 的执行逻辑**：

   ```Bash
   # 跟踪 Operator 如何处理我们的修改请求
   kubectl logs -l app.kubernetes.io/name=mongodb-kubernetes-operator -n mongodb -f
   ```

------

### 第三阶段：强力干预与状态验证

由于内存太低，Operator 自动删除 Pod 的过程非常缓慢，我们执行了手动干预：

1. **强制释放内存**：

   ```Bash
   # 手动删掉多余的副本，立刻给系统腾出 500MB+ 空间
   kubectl delete pod ops-mongo-2 -n mongodb --force
   kubectl delete pod ops-mongo-1 -n mongodb --force
   ```

2. **验证最终状态**：

   ```Bash
   # 确认只剩一个 ops-mongo-0 且处于 Running 状态
   kubectl get pods -n mongodb
   
   # 确认内存限制是否生效
   kubectl describe pod ops-mongo-0 -n mongodb | grep -A 2 Limits
   ```

3. **检查系统健康度**：

   ```Bash
   # 再次查看 top，确认 avail Mem 回升，si (软中断) 稳定
   top
   ```
