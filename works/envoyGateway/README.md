# 🚀 Envoy Gateway + OpenELB 部署全流程指南

本手册记录了在 Linux 裸机（Bare-metal）环境下，使用 **Envoy Gateway** 作为入口网关，并配合 **OpenELB** 实现 Layer2 模式下自动分配 LoadBalancer IP 的完整实战过程。

------

## 一、 核心组件角色定义

| 组件              | 角色              | 作用                                               |
| ----------------- | ----------------- | -------------------------------------------------- |
| **Envoy Gateway** | **大脑 (控制面)** | 监控 Gateway API 资源，下发指令给 Envoy。          |
| **Envoy Proxy**   | **手脚 (数据面)** | 真实处理流量的 Pod，执行路由、TLS 卸载和负载均衡。 |
| **OpenELB**       | **资源经理**      | 负责给 Service 盖章并分配局域网物理 IP。           |

Export to Sheets

------

## 二、 详细安装与部署流程

### 1. 安装 Envoy Gateway (Helm)

首先使用 YAML安装控制器。

```bash
wget https://github.com/envoyproxy/gateway/releases/download/v1.6.3/install.yaml
kubectl apply --server-side -f install.yaml
```

### 2. 配置 OpenELB IP 池 (EIP)

在网关启动前，必须准备好 IP 资源。

```yaml
apiVersion: network.kubesphere.io/v1alpha2
kind: Eip
metadata:
  name: eip-pool
  # 关键点：设置为默认池，避免后续关联失败
  labels:
    networking.kubesphere.io/is-default-eip: "true"
spec:
  address: 10.0.0.141-10.0.0.210 # 确保此范围在你的局域网内且未被占用
  interface: ens33              # 你的网卡名称
  protocol: layer2
kubectl apply -f eip.yaml
```

### 3. 定义部署蓝图 (EnvoyProxy)

这是你之前的“排坑”核心。它定义了 Envoy 生成 Service 时必须带上的 OpenELB 注解。

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDaemonSet: # 采用 DaemonSet 模式，每台机器一个保安
        pod:
          nodeSelector:
            gateway: "true" # 仅在打标为 gateway=true 的节点部署
      envoyService:    # 核心：定义 Service 自动生成的属性
        type: LoadBalancer
        annotations:
          lb.kubesphere.io/v1alpha1: openelb
          protocol.openelb.kubesphere.io/v1alpha1: layer2
```

### 4. 关联标准 (GatewayClass)

将蓝图与 Gateway 类绑定。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg-daemonset
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy
    namespace: envoy-gateway-system
```

### 5. 实例化网关 (Gateway)

正式开启网关入口。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: eg-daemonset # 引用上面的标准
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
```

### 6. 配置业务转发 (HTTPRoute)

将域名访问导向你的 Nginx。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-route
spec:
  parentRefs:
  - name: my-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: / }
    backendRefs:
    - name: nginx-service # 你的后端应用 Service 名
      port: 80
```

------

## 三、 流量穿透原理

1. **入口**：外部流量到达 OpenELB 分配的 VIP（如 `10.0.0.141`）。
2. **处理**：流量进入 `envoy:v1.33.0` 容器，Envoy 根据 `HTTPRoute` 识别请求。
3. **直达**：Envoy 查看内存中的 **EndpointSlice**，直接将流量发给后端 Pod 的 **私有 IP**。

------

## 四、 常见问题排查 (Cheat Sheet)

| 现象                | 排查命令                                                     | 常见原因                                      |
| ------------------- | ------------------------------------------------------------ | --------------------------------------------- |
| **Service Pending** | `kubectl get eip`                                            | IP 池未 Ready 或 `is-default-eip` 标签没打。  |
| **Pod 没创建**      | `kubectl describe gateway`                                   | `gatewayClassName` 写错或控制器镜像拉不下来。 |
| **配置不生效**      | `kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway` | EnvoyProxy YAML 格式错误，控制面“大脑”报错。  |
| **访问 404**        | `kubectl get httproute`                                      | 路由没有正确绑定到 Gateway 的 Listener 上。   |

