## 安装velero客户端
```bash
wget https://github.com/vmware-tanzu/velero/releases/download/v1.17.2/velero-v1.17.2-linux-arm64.tar.gz
tar xvf velero-v1.17.2-linux-arm64.tar.gz
cp velero-v1.17.2-linux-arm64/velero /usr/local/bin
velero --version
```

## 安装cfssl生成证书文件
```bash
apt-get update && apt-get install golang-cfssl
cfssl gencert   -ca=/etc/kubernetes/pki/ca.crt   -ca-key=/etc/kubernetes/pki/ca.key   -config=ca-config.json   -profile=kubernetes   velero-csr.json | cfssljson -bare velero
cp velero-key.pem /etc/kubernetes/pki/
cp velero.pem /etc/kubernetes/pki/
```

## 创建kubeconfig文件和role
```bash
kubectl config set-cluster kubernetes --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true --server=https://10.0.0.135:6443 --kubeconfig=./velero.kubeconfig

kubectl config set-credentials velero --client-certificate=/etc/kubernetes/pki/velero.pem --client-key=/etc/kubernetes/pki/velero-key.pem --embed-certs=true --kubeconfig=./velero.kubeconfig

kubectl config set-context kubernetes --cluster=kubernetes --user=velero --namespace=default --kubeconfig=./velero.kubeconfig

kubectl config use-context kubernetes --kubeconfig=/data/velero/velero.kubeconfig

kubectl create clusterrolebinding velero-admin-binding   --clusterrole=cluster-admin   --user=velero --dry-run=client -o yaml > clusterrolebinding.yaml
kubectl apply -f clusterrolebinding.yaml
```

## 设置AccessKey文件
```
ALIBABA_CLOUD_ACCESS_KEY_ID=xxx
ALIBABA_CLOUD_ACCESS_KEY_SECRET=xxx
```

## 利用velero客户端安装
```bash
kubectl create ns velero-system

velero install \
  --provider alibabacloud \
  --plugins registry-cn-hangzhou.ack.aliyuncs.com/acs/velero-plugin-alibabacloud:v2.0.0-eaad098 \
  --image docker.m.daocloud.io/velero/velero:v1.17.2 \
  --bucket k8s28 \
  --secret-file ./credentials-velero \
  --use-node-agent \
  --namespace velero-system \
  --backup-location-config region=cn-beijing,network=public \
  --kubeconfig ./velero.kubeconfig
```

查看日志
```
```

## 测试
```bash
velero backup create oss-final-test --include-namespaces velero-system --namespace velero-system

velero backup get --namespace velero-system

# 删除备份
velero backup delete oss-final-test --namespace velero-system --confirm
```

## 删除
```bash
velero uninstall \
  --namespace velero-system \
  --kubeconfig ./velero.kubeconfig
```

