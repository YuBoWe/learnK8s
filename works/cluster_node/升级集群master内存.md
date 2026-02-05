# 扩展k8s集群master节点的内存

## 备份

1. 核心证书备份（必须做）

这是 K8s 集群的“身份令牌”。虽然 Master2 上也有一份，但手动备份 Master1 的证书是防止集群失联的最后一道防线。

```sh
# 创建备份目录
mkdir -p /root/k8s_backup/pki

# 备份所有证书和密钥
cp -rp /etc/kubernetes/pki/* /root/k8s_backup/pki/

# 备份管理员配置文件 (用于以后恢复 kubectl 权限)
cp /etc/kubernetes/admin.conf /root/k8s_backup/
```

2. 静态 Pod 定义文件备份

这里记录了你 ApiServer、Etcd 等组件的启动参数。

```sh
mkdir -p /root/k8s_backup/manifests
cp -p /etc/kubernetes/manifests/*.yaml /root/k8s_backup/manifests/
```



3. Etcd 数据快照

```sh
# 获取etcd的image标签
crictl ps | grep etcd

crictl exec 9b29ecdb6c752 /usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/k8s_backup/etcd_snapshot.db
```

## 修改DNS



## 移除master1

1. 在 Master1 上移除自己

```sh
crictl exec 9b29ecdb6c752 /usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member remove 20f32bad2ee0bc02
```

2. 执行后续清理与关机

```sh
# 1. 彻底清除 Master1 的 K8s 配置
kubeadm reset -f

# 2. 关机准备升级内存
poweroff
```

- **Master2：** 它的 Etcd 会短暂报一下错（因为发现 Master1 丢了），但由于我们刚才手动执行了 `remove`，它会自动调整法定人数为 1，然后重新恢复正常。
- **业务：**  Workers（137-139）会继续跑现有的 Pod。



## 重新加入集群

第一步：在 Master2 上签发“入场券”

因为集群现在由 Master2 说了算，我们需要在 **Master2** 上生成证书密钥和加入命令:

```sh
# 在 Master2 执行，这会上传证书并生成令牌
kubeadm token create --print-join-command --certificate-key $(kubeadm init phase upload-certs --upload-certs | tail -1)
```

第二步：在 Master1 上执行加入

把刚才在 Master2 上拿到的那一长串命令，直接粘贴到 **Master1** 的终端里执行。

```
kubeadm join 10.0.0.135:6443 --token ... --discovery-token-ca-cert-hash ... --control-plane --certificate-key ...
```

第三步：验证成果

```
kubectl get nodes
```

## 验证步骤

在master1上执行

```sh
# 1. 查看节点状态
kubectl get nodes

# 2. 确认 Etcd 成员再次变回两个
export ETCDCTL_API=3
crictl ps | grep etcd  # 先拿到新的容器 ID
# 假设新容器 ID 是 <New_ID>
crictl exec <New_ID> /usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```



# 将k8s集群的master降级为worker

## 将master移出集群

__第一步：在 Master1 上移除 Master2 (Etcd 层面)__

在 **Master1** 上执行，告诉集群以后 Master2 不再参与投票了

```
crictl exec 5ca60d3d60d50 /usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member remove c6407515b6d3cb6d
```

__第二步：清理 Master2 并重新加入__

1. 在 Master2 上执行彻底重置：

```sh
kubeadm reset -f
# 清理残留目录
rm -rf /etc/kubernetes/

# 清理之前的 cni 网络插件缓存
rm -rf /var/lib/cni/
rm -rf /var/lib/kubelet/*
rm -rf /etc/cni/net.d/

mkdir -p /etc/kubernetes/
```

2. **在 Master1 上生成普通的 Join 命令：** （注意：这次**不要**加 `--control-plane` 参数，因为我们要它做 Worker)，并清理master2

```
kubectl delete node master2.k8s.com

kubeadm token create --print-join-command
```



## 重新加入集群

**在 Master2 上执行加入命令：** 将刚才生成的命令粘贴到 **Master2** 执行。

如果长时间node not ready，先用describe查看event

```sh
kubectl describe nodes worker4.k8s.com

## 出现：
  Type     Reason                   Age                  From             Message
  ----     ------                   ----                 ----             -------
  Normal   Starting                 9m4s                 kube-proxy       
```

应该是网络插件出现问题了，排查：

```sh
kubectl get nodes worker4.k8s.com -o yaml | grep -A 5 "conditions"
## 出现如下：
  conditions:
  - lastHeartbeatTime: "2026-02-04T11:00:18Z"
    lastTransitionTime: "2026-02-04T11:00:18Z"
    message: Flannel is running on this node
    reason: FlannelIsUp
    status: "False"
```

`tatus: "False"`，而且 `reason: FlannelIsUp`。 这非常具有欺骗性。Flannel 报称它在运行（Up），但它的 **Ready 状态却是 False**。这通常意味着 **Flannel 的子网文件 (subnet.env) 没生成** 或者 **网桥 (cni0) 冲突了**。

彻底清除 Flannel 残留 (在 worker4 执行)

```sh
# 停止服务
systemctl stop kubelet

# 删除旧的网桥和 Flannel 配置
ip link set cni0 down || true
ip link delete cni0 || true
ip link set flannel.1 down || true
ip link delete flannel.1 || true

# 清理配置文件目录（这是关键！）
rm -rf /var/lib/cni/*
rm -rf /etc/cni/net.d/*

# 重新启动
systemctl start kubelet
```

Flannel 启动时会去 `/run/flannel/subnet.env` 找子网信息。如果没有，它就没法创建 `cni0`

```sh
cat /run/flannel/subnet.env

# FLANNEL_NETWORK=10.244.0.0/16
# FLANNEL_SUBNET=10.244.4.1/24
# FLANNEL_MTU=1450
# FLANNEL_IPMASQ=true
```

确认 CNI 配置是否存在

```sh
# 在 worker4 上看一眼这个目录
ls /etc/cni/net.d/
```

__如果这里面是空的，或者只有旧的备份文件，那就是问题所在。__

```sh
mkdir -p /etc/cni/net.d/

cat <<EOF > /etc/cni/net.d/10-flannel.conflist
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOF
```

重启服务，让配置生效

```sh
systemctl restart containerd
systemctl restart kubelet
```

# 重启集群proxy和coredns
```
# 清理 kube-proxy 生成的旧规则
kube-proxy --cleanup
# 如果没有 kube-proxy 命令，手动刷新
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
# 重启 kube-proxy pod 会自动重建正确规则 (在 Master1 执行)
kubectl delete pod -n kube-system -l k8s-app=kube-proxy

kubectl rollout restart deployment coredns -n kube-system
```

# worker节点优化及重启container和kubelet
注意到：
```
journalctl -u kubelet -f
Feb 05 11:04:48 worker1.k8s.com kubelet[3223]: E0205 11:04:48.965177    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:49 worker1.k8s.com kubelet[3223]: E0205 11:04:49.966084    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:50 worker1.k8s.com kubelet[3223]: E0205 11:04:50.967484    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:50 worker1.k8s.com kubelet[3223]: E0205 11:04:50.990087    3223 file.go:104] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:51 worker1.k8s.com kubelet[3223]: E0205 11:04:51.968002    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:52 worker1.k8s.com kubelet[3223]: E0205 11:04:52.969237    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:53 worker1.k8s.com kubelet[3223]: E0205 11:04:53.969893    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:54 worker1.k8s.com kubelet[3223]: E0205 11:04:54.970164    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:55 worker1.k8s.com kubelet[3223]: E0205 11:04:55.970289    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:56 worker1.k8s.com kubelet[3223]: E0205 11:04:56.971200    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:57 worker1.k8s.com kubelet[3223]: E0205 11:04:57.971582    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:58 worker1.k8s.com kubelet[3223]: E0205 11:04:58.972320    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: I0205 11:04:59.810312    3223 scope.go:117] "RemoveContainer" containerID="d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.813269    3223 remote_runtime.go:385] "RemoveContainer from runtime service failed" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a\": cannot delete running task d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a: failed precondition" containerID="d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.813396    3223 kuberuntime_gc.go:150] "Failed to remove container" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a\": cannot delete running task d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a: failed precondition" containerID="d6aef2230829c227ab9bae26c6ca36f3f49d406126b11f565b21c6795824156a"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: I0205 11:04:59.813420    3223 scope.go:117] "RemoveContainer" containerID="2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.815336    3223 remote_runtime.go:385] "RemoveContainer from runtime service failed" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988\": cannot delete running task 2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988: failed precondition" containerID="2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.815390    3223 kuberuntime_gc.go:150] "Failed to remove container" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988\": cannot delete running task 2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988: failed precondition" containerID="2e3b63e31291da6fda5fbf9c98d05b296030a7d51acebef5646d9db7c560b988"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: I0205 11:04:59.815424    3223 scope.go:117] "RemoveContainer" containerID="0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.817061    3223 remote_runtime.go:385] "RemoveContainer from runtime service failed" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b\": cannot delete running task 0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b: failed precondition" containerID="0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.817091    3223 kuberuntime_gc.go:150] "Failed to remove container" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b\": cannot delete running task 0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b: failed precondition" containerID="0f349ab378f03e325aefacc6e63cbafd51fa4402e6aaa4843ef51e994a7e3c5b"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: I0205 11:04:59.817105    3223 scope.go:117] "RemoveContainer" containerID="bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.818597    3223 remote_runtime.go:385] "RemoveContainer from runtime service failed" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d\": cannot delete running task bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d: failed precondition" containerID="bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.818636    3223 kuberuntime_gc.go:150] "Failed to remove container" err="rpc error: code = FailedPrecondition desc = failed to delete containerd container \"bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d\": cannot delete running task bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d: failed precondition" containerID="bd233074b918334ef820e83df83bf8dde170ff95cd65839a8e6e6c19e430c47d"
Feb 05 11:04:59 worker1.k8s.com kubelet[3223]: E0205 11:04:59.972630    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:05:00 worker1.k8s.com kubelet[3223]: E0205 11:05:00.972984    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:05:01 worker1.k8s.com kubelet[3223]: E0205 11:05:01.974168    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:05:02 worker1.k8s.com kubelet[3223]: E0205 11:05:02.975030    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
Feb 05 11:05:03 worker1.k8s.com kubelet[3223]: E0205 11:05:03.975908    3223 file_linux.go:61] "Unable to read config path" err="path does not exist, ignoring" path="/etc/kubernetes/manifests"
```
__病灶 A：/etc/kubernetes/manifests 缺失 (高频报错)__
- 现象：Kubelet 一直在报 Unable to read config path。

- 分析：这是因为 Kubelet 的配置中开启了 Static Pod（静态 Pod）扫描，但这个目录在 worker 节点上不存在（通常只有 Master 节点才用这个目录跑 API Server 等组件）。

- 影响：这虽然不会导致节点挂掉，但会产生大量日志噪音，占用系统 IO 和 CPU。

__病灶 B：容器删除失败 (FailedPrecondition)__
- 现象：cannot delete running task ... failed precondition。

- 分析：这是 kubelet 和 containerd 之间的通信打架了。Kubelet 想要回收（GC）一些旧容器，但 containerd 认为这些容器的任务还在运行，不能直接删除。

- 原因：这通常是因为你之前调整集群架构、重启 Master 导致连接重置后，Worker 节点上的容器状态与 Master 的预期不一致，产生了一些“僵尸任务”。

解决方案：
```bash
mkdir -p /etc/kubernetes/manifests
systemctl restart containerd
systemctl restart kubelet
```














