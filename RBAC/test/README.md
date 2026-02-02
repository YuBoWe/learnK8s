## 1. 场景一：使用“数字证书”配置访问 (Dev 模式)

假设你已经在远程 Master 节点为用户 `mason` 签发了证书（CN=mason, O=developers），现在需要将这些文件拷贝到本地机器，并配置 `kubectl`。

### 步骤 A：下载凭据

将 `ca.crt`, `mason.crt`, `mason.key` 拷贝到客户端本地目录。

### 步骤 B：执行 kubectl 配置命令

> [!TIP]
> 使用 `--embed-certs=true` 可以将证书内容直接写入 config 文件，这样移动 config 文件时就不需要带着证书原文件了。

```bash
# 1. 设置集群端点 (注意此处必须是 API Server 的远程公网/私网 IP)
kubectl config set-cluster my-prod \
  --server=https://10.0.0.135:6443 \
  --certificate-authority=./ca.crt \
  --embed-certs=true \
  --kubeconfig=mason.conf

# 2. 设置用户凭据 (关联刚刚下载的 crt 和 key)
kubectl config set-credentials mason \
  --client-certificate=./mason.crt \
  --client-key=./mason.key \
  --embed-certs=true \
  --kubeconfig=mason.conf

# 3. 设置上下文 (Context)，将集群、用户、默认 Namespace 绑定
kubectl config set-context mason@prod \
  --cluster=my-prod \
  --user=mason \
  --namespace=default \
  --kubeconfig=mason.conf

# 4. 激活并使用
kubectl config use-context mason@prod --kubeconfig=mason.conf
```

---

测试

```
kubectl get pods --kubeconfig=dev-user.conf
export KUBECONFIG=$(pwd)/dev-user.conf
```


## 2. 场景二：使用“Token”配置访问 (CI/CD 模式)

这种方式不需要 crt/key 文件，非常适合 Jenkins、GitLab 或临时分配权限。

### 步骤 A：在 Master 节点生成 Token

```bash
# 创建一个 ServiceAccount 并生成一个 100000小时有效期的 Token
kubectl create serviceaccount automation -n test
# 生成 Token 并记录下来
TOKEN=$(kubectl create token automation --duration=100000h)
echo $TOKEN
```

### 步骤 B：在客户端配置 kubectl

```bash
# 1. 设置集群 (只需要 CA 证书)
kubectl config set-cluster my-prod \
  --server=https://10.0.0.135:6443 \
  --certificate-authority=./ca.crt \
  --embed-certs=true \
  --kubeconfig=auto.conf

# 2. 设置用户 (直接传入 Token 字符串)
kubectl config set-credentials robot \
  --token="${TOKEN}" \
  --kubeconfig=auto.conf

# 3. 设置上下文
kubectl config set-context robot@prod \
  --cluster=my-prod \
  --user=robot \
  --kubeconfig=auto.conf

# 4. 使用
kubectl config use-context robot@prod --kubeconfig=auto.conf
```

---

测试：

```
kubectl create role pod-get-list --verb=get,list --resource=pods -n openelb-system --dry-run=client -o yaml > role-pod-get-list.yaml

kubectl create rolebinding pod-get-list-binding --role=pod-get-list --serviceaccount=test:automation -n openelb-system --dry-run=client -o yaml > rolebinding-pod-get-list.yaml
```

在work中将config移动到.kube/下
