# 部署grafana
环境有openebs作pv动态置备，sc名为openebs-hostpath
## 部署secret（grafana初始密码和admin）
```sh
kubectl apply -f secret-user-password.yaml
```

## 部署grafana配置文件的cm
```sh
kubectl apply -f cm-grafana-ini.yaml
```
## 创建role和rolebinding
让sidecar有权限去查看configmap资源，默认default没有此权限
```
kubectl apply -f grafana-rbac.yaml 
```

## 部署grafana的container和sidercar
sidercar用来让grafana面板实现“声明式”自动化, 同时使用openebs时设置fgroup
```
kubectl apply -f dp-grafana.yaml
```

## Example：加入mysql的dashboard
```sh
kubectl create configmap grafana-dashboard-mysql-overview \
  --from-file=mysql-overview.json=./mysql-overview.json \
  -n monitor

kubectl label cm grafana-dashboard-mysql-overview grafana_dashboard="1" -n monitor
```

查看边车pod日志
```
kubectl logs <pod名称> -c grafana-sc-dashboard -n monitor
```
