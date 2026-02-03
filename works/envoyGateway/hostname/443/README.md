# 📝 Envoy Gateway HTTPS 部署实战技术文档

## 1. 架构概览

- **基础设施层**：使用 OpenELB 提供 Layer2 VIP (10.0.0.144)。
- **网关层**：Envoy Gateway 以 **DaemonSet** 模式部署，确保每个节点都有网关实例。
- **协议标准**：使用 Kubernetes **Gateway API** (v1)。
- **核心功能**：TLS 卸载 (Termination)、SNI 多域名匹配、HTTP 强制跳转 HTTPS。

------

## 2. 部署步骤实录

### 第一步：证书准备 (Self-Signed)

生成针对自定义域名 `nginx.fakecyber.com` 的自签名证书并存入 K8s Secret。

Bash

```
# 生成证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=nginx.fakecyber.com"

# 创建 Secret
kubectl create secret tls nginx-tls-cert --cert=tls.crt --key=tls.key
```

### 第二步：配置 Gateway 监听器

在 `Gateway` 资源中同时开启 80 (HTTP) 和 443 (HTTPS) 端口。

- **关键配置**：在 443 端口下引用 `nginx-tls-cert`，模式设为 `Terminate`。

### 第三步：路由逻辑拆分 (核心防坑点)

为了避免“无限重定向”死循环，将 HTTP 和 HTTPS 的处理逻辑拆分为两个 `HTTPRoute` 资源。

1. **重定向路由 (`nginx-redirect-route`)**：
   - 绑定 `sectionName: http`。
   - 过滤器：`RequestRedirect`，强制跳转至 `https`，状态码 `301`。
2. **业务转发路由 (`nginx-https-route`)**：
   - 绑定 `sectionName: https`。
   - 后端：指向 `nginx` Service 的 80 端口。

------

## 3. 关键问题排查与解决

| 现象                       | 原因                              | 解决方法                                                     |
| -------------------------- | --------------------------------- | ------------------------------------------------------------ |
| `Connection reset by peer` | 访问 HTTPS 时未提供 SNI 域名      | 使用 `curl --resolve` 强行指定域名。                         |
| `ERR_TOO_MANY_REDIRECTS`   | HTTP 和 HTTPS 共享了跳转规则      | 拆分 HTTPRoute，通过 `sectionName` 隔离流量。                |
| `PR_END_OF_FILE_ERROR`     | 浏览器代理拦截或 Firefox DoH 开启 | 关闭代理软件绕过、关闭 Firefox 的 DNS over HTTPS。           |
| 域名无法解析               | 本地电脑不知道域名的 IP 映射      | 修改本地 `/etc/hosts`，添加 `10.0.0.144 nginx.fakecyber.com`。 |

Export to Sheets

------

## 4. 验证命令清单

- **验证 HTTP 自动跳转**：

  Bash

  ```
  curl -I http://10.0.0.144 -H "Host: nginx.fakecyber.com"
  # 结果：HTTP/1.1 301 Moved Permanently, Location: https://...
  ```

- **验证 HTTPS 正常访问**：

  Bash

  ```
  curl -kI https://nginx.fakecyber.com --resolve nginx.fakecyber.com:443:10.0.0.144
  # 结果：HTTP/2 200 OK
  ```

------

## 5. 架构优势总结

1. **高性能**：Envoy 数据面原生支持 TLS 1.3 和 HTTP/2，DaemonSet 确保了流量本地化。
2. **高可用**：OpenELB VIP + 多节点 Envoy 实例，无单点故障。
3. **标准化**：完全遵循 Kubernetes Gateway API 规范，方便未来迁移或扩展限流、鉴权等插件。

------

**📌 提示**：在浏览器访问时，由于是自签名证书，需手动点击“高级” -> “继续前往”或输入 `thisisunsafe` 绕过安全警告。
