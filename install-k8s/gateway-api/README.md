## Gateway API + Envoy Gateway（K8s 1.33）

### 推荐版本

| 组件 | 版本 |
|------|------|
| Kubernetes | 1.33 |
| Gateway API CRD | **v1.5.1** |
| Envoy Gateway | **v1.8.2** |
| Envoy Proxy | distroless-v1.38.0 |
| Rate Limit | 1e50889b |

默认使用官方镜像 `docker.io/envoyproxy/...`。设置 `IMAGE_REGISTRY` 后按源路径拼接，例如：

`registry.cn-global.starbucket.com.cn/starbucket/docker.m.daocloud.io/envoyproxy/gateway:v1.8.2`

### 脚本一览

| 脚本 | 作用 |
|------|------|
| `sync-images.sh` | （可选）把官方镜像同步到私有仓 |
| `install-eg.sh` | 一键安装 Gateway API + Envoy Gateway |
| `uninstall-gateway.sh` | **一键彻底卸载**（CRD / 命名空间 / Webhook / RBAC） |
| `eg-values.yaml` | Helm values |
| `eg-proxy.yaml` | 数据面镜像 + GatewayClass（默认 **NodePort**） |
| `ensure-envoy-nodeport.sh` | 创建 Gateway 后纠正数据面为 NodePort + Cluster |
| `eg-proxy-loadbalancer.yaml` | （可选）数据面改为 MetalLB LoadBalancer |
| `ensure-envoy-loadbalancer.sh` | （可选）NodePort → MetalLB VIP，等待 EXTERNAL-IP |

---

### 1. （可选）同步镜像到私有仓

```bash
export PRIVATE_REGISTRY=registry.example.com/myproj
docker login <你的仓库域名>
bash sync-images.sh
```

同步后的镜像形如：

```text
${IMAGE_REGISTRY}/docker.m.daocloud.io/envoyproxy/gateway:v1.8.2
${IMAGE_REGISTRY}/docker.m.daocloud.io/envoyproxy/envoy:distroless-v1.38.0
${IMAGE_REGISTRY}/docker.m.daocloud.io/envoyproxy/ratelimit:1e50889b
```

---

### 2. 一键安装

```bash
export GH_PROXY="${GH_PROXY:-https://ghfast.top/}"
# 可选：使用私有仓（与 sync-images.sh 的 PRIVATE_REGISTRY 一致）
# export IMAGE_REGISTRY=registry.example.com/myproj
bash install-eg.sh
```

说明：
- 使用 Gateway API **standard** v1.5.1（不要装 experimental）
- 未设置 `IMAGE_REGISTRY` 时用官方镜像；设置后自动替换控制器与数据面镜像
- 不依赖 `docker.io` 拉 Helm chart（直接用 GitHub release 的 install.yaml）
- CRD / 控制器清单一律拆成**单资源文件**，**严格串行** `kubectl apply`（禁止整包并行，降低 etcd 超时）
- 每个 CRD 会等到 `Established` 后再处理下一个
- 下载失败会自动换 GitHub 代理；脚本内已设置版本号，**不要**在 shell 里用空的 `${GATEWAY_API_VERSION}` / `${TMPDIR}` 手敲 curl

手动下载（变量写死，避免 404）：

```bash
export GH_PROXY=https://ghfast.top/
curl -fL -o /tmp/gateway-api.yaml \
  "${GH_PROXY}https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml"
ls -lh /tmp/gateway-api.yaml   # 约 1MB
```

若安装时出现 `etcdserver: request timed out` / `GOAWAY`：

```bash
# 1) 等 API 恢复
kubectl get --raw=/readyz

# 2) 直接重跑即可（已应用的 CRD 会跳过/幂等；全程串行）
export KUBECTL_TIMEOUT=300s APPLY_RETRIES=8 APPLY_SLEEP=5
bash install-eg.sh
```

可选环境变量：`KUBECTL_TIMEOUT`（默认 180s）、`APPLY_RETRIES`（默认 6）、`APPLY_SLEEP`（默认 3 秒）、`IMAGE_REGISTRY`（私有仓前缀）。

安装后创建入口，并**立刻**纠正数据面 Service（默认 NodePort）：

```bash
kubectl apply -f examples/gateway-http.yaml

bash ensure-envoy-nodeport.sh

kubectl get gateway eg -o wide
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg
```

期望：`TYPE=NodePort`，`externalTrafficPolicy=Cluster`。访问 `http://<任意节点IP>:<NodePort>/`。

需要 **80/443 虚拟 IP** 时，再按 **2.1** 改成 MetalLB（不是默认安装步骤）。

---

### 2.1 （可选）改成 MetalLB LoadBalancer

默认安装是 NodePort。要把入口改成局域网 VIP（默认 **`172.16.10.250:80`**）时，单独执行下面步骤。

**不要占用 `172.16.10.100`**（kube-apiserver keepalived VIP）。`172.16.10.250` 是 MetalLB L2 宣告的另一个 VIP。

#### 步骤

```bash
# 1) 安装 MetalLB + 地址池（默认 172.16.10.250/32）
cd /opt/k8s-script/install-k8s/metallb
# 改 VIP 时先编辑 ipaddresspool.yaml，并同步改 gateway-api/eg-proxy-loadbalancer.yaml 里的 annotation
bash install-metallb.sh

# 2) Gateway 已存在（没有则先 apply）
cd /opt/k8s-script/install-k8s/gateway-api
kubectl apply -f examples/gateway-http.yaml

# 3) 数据面 NodePort → LoadBalancer，等待 EXTERNAL-IP
bash ensure-envoy-loadbalancer.sh
```

脚本会 apply `eg-proxy-loadbalancer.yaml`（同一 `EnvoyProxy/eg-proxy`），并给数据面 Service 加上 annotation `metallb.universe.tf/loadBalancerIPs`。

期望：

```text
TYPE=LoadBalancer   EXTERNAL-IP=172.16.10.250   PORT(S)=80:xxxxx/TCP
```

`PORT(S)` 里仍会带 NodePort，这是 LoadBalancer 的正常附带端口。对外用 VIP 的 **80/443**，域名 A 记录指到 `172.16.10.250`。

HTTPS：Secret `default/star.obsbot.lan` 已存在时 apply `examples/gateway-http.yaml`（含 443 listener），再确认数据面 Service 出现 443。

#### 改 VIP 地址

同时改三处为同一 IP：

1. `install-k8s/metallb/ipaddresspool.yaml` 的 `addresses`
2. `install-k8s/gateway-api/eg-proxy-loadbalancer.yaml` 的 `metallb.universe.tf/loadBalancerIPs`
3. 环境变量 `LB_IP`（可选）：`LB_IP=172.16.10.201 bash ensure-envoy-loadbalancer.sh`

#### 注意（踩过的坑）

| 不要 | 原因 |
|------|------|
| 同时写 `spec.loadBalancerIP` 和 annotation `metallb.universe.tf/loadBalancerIPs` | MetalLB 报错，EXTERNAL-IP 永远 pending |
| 写 `loadBalancerClass: metallb` | MetalLB v0.14 原生 manifest **没有** LoadBalancerClass CR |

排查：

```bash
kubectl -n metallb-system get pods
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl -n metallb-system logs deploy/controller --tail=40
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg
curl -sI http://172.16.10.250/
```

若要改回 NodePort：`bash ensure-envoy-nodeport.sh`（会重新 apply 默认的 `eg-proxy.yaml`）。

---

### 3. 一键卸载（清理干净）

会删除：全部 `HTTPRoute` / `Gateway` / `GatewayClass`、命名空间 `envoy-gateway-system`、Envoy Gateway 与 Gateway API 的 CRD、Webhook、AdmissionPolicy、相关 ClusterRole。

```bash
# 交互确认
bash uninstall-gateway.sh

# 跳过确认（适合脚本/CI）
bash uninstall-gateway.sh --yes
```

卸载后自检（应无输出）：

```bash
kubectl get ns | grep envoy-gateway || echo "无 envoy-gateway 命名空间"
kubectl get crd | grep -E 'gateway\.(networking|envoyproxy)' || echo "无 gateway 相关 CRD"
```

若提示仍有残留，再执行一次：

```bash
bash uninstall-gateway.sh --yes
```

重装：

```bash
bash install-eg.sh
```

重装后创建 Gateway，再执行 `bash ensure-envoy-nodeport.sh`。若要用 MetalLB，再按 2.1 执行 `bash ensure-envoy-loadbalancer.sh`。

---

### 4. 业务路由：HTTPRoute / GRPCRoute

HTTP 与 gRPC **共用同一个 Gateway**（同一 NodePort），用路径或域名区分。示例见 `examples/`。

#### 4.1 HTTPRoute（HTTP）

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-http
  namespace: default
spec:
  parentRefs:
    - name: eg                 # 挂到 Gateway/eg
  hostnames:
    - "demo.example.com"       # 可选
  rules:
    - matches:
        - path:
            type: PathPrefix   # Exact | PathPrefix | RegularExpression
            value: /app
      backendRefs:
        - name: demo-svc       # Service 名
          port: 8080
```

```bash
kubectl apply -f examples/httproute-demo.yaml
kubectl get httproute -A
# curl -H 'Host: demo.example.com' http://<节点IP>:<NodePort>/app/
```

#### 4.2 GRPCRoute（gRPC）

gRPC 走 HTTP/2，挂在 Gateway 的 **HTTP**（明文）或 **HTTPS**（TLS） listener 上：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: demo-grpc
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "grpc.example.com"
  rules:
    - matches:
        - method:
            service: helloworld.Greeter
            method: SayHello
      backendRefs:
        - name: grpc-svc
          port: 9000
```

```bash
kubectl apply -f examples/grpcroute-demo.yaml
kubectl get grpcroute -A
# grpcurl -plaintext -authority grpc.example.com \
#   <节点IP>:<NodePort> helloworld.Greeter/SayHello
```

后端 Service 的 `port` 必须是 **Service 的 port**（不是 targetPort 名字随意写；与 Service.spec.ports[].port 一致）。

多个服务共用**同一 Gateway 端口**，用路径或域名区分，不必为每个服务开新 NodePort。

HTTP 与 gRPC **要分两个资源**（`HTTPRoute` / `GRPCRoute`），可写在同一 YAML 文件里用 `---` 分隔；不能写进同一个 Route 对象。

日常 gRPC **不必**写 `method.service` / `method.method`，整服务转发只配 `backendRefs` 即可；只有按 RPC 拆到不同后端时才写方法匹配。

#### 4.3 修改响应头 `Server`（如 nginx → Gateway）

后端 Nginx 常返回 `Server: nginx/1.24.0`。Envoy Gateway 默认往往会**透传**上游 `Server`，要在 Gateway 侧改成 `Server: Gateway`。

> 注意：`HTTPRoute` 的 `ResponseHeaderModifier` 对 `Server` 这个特殊头**经常无效**，不要只依赖它。

**方式一（优先）：`ClientTrafficPolicy` 全局改写**

```bash
kubectl apply -f examples/clienttrafficpolicy-server-header.yaml
```

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: set-server-header
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  headers:
    lateResponseHeaders:
      set:
        - name: Server
          value: Gateway
```

验证：

```bash
curl -sI http://<节点IP>:<NodePort>/ | grep -i server
# 期望: server: Gateway
```

**方式二：仍是 nginx 时用 `EnvoyPatchPolicy`（强制 OVERWRITE）**

需先开启控制器的 EnvoyPatchPolicy（`EnvoyGateway` / 配置里）：

```yaml
extensionApis:
  enableEnvoyPatchPolicy: true
```

然后：

```bash
kubectl apply -f examples/envoypatch-server-header.yaml
```

该清单对 listener `default/eg/http` 设置：

- `server_name: Gateway`
- `server_header_transformation: OVERWRITE`

若 Gateway/listener 名不同，改 patch 里的 `name: <ns>/<gateway>/<listener>`。

| 做法 | 说明 |
|------|------|
| `ResponseHeaderModifier` | 对 `Server` 常无效 |
| `ClientTrafficPolicy` late set | 先试，全 Gateway 生效 |
| `EnvoyPatchPolicy` | 最稳，直接改 Envoy HCM |

---

### 5. 常用查看命令

```bash
kubectl get gatewayclass
kubectl get gateway -A -o wide
kubectl get httproute,grpcroute -A
# 路由是否 Accepted
kubectl get httproute,grpcroute -A -o wide
kubectl describe httproute -A
kubectl describe grpcroute -A
kubectl -n envoy-gateway-system get pods,svc
# 确认多节点可访问：应为 type=NodePort externalTrafficPolicy=Cluster
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,POLICY:.spec.externalTrafficPolicy,NODEPORT:.spec.ports[0].nodePort
```

> Kuboard 默认只支持 Ingress，一般看不到 HTTPRoute 图形界面；请用 `kubectl` 或 Routeboard 等 Gateway API 看板。

---

### 6. 查看 Gateway 转发 / 访问日志

转发日志在**数据面 Envoy**（处理流量的 Pod），不在控制面 `envoy-gateway` Deployment。

```bash
# 列出数据面 Pod
kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=eg

# 实时看访问日志（JSON，含 method / path / response_code / route_name / upstream_host）
kubectl -n envoy-gateway-system logs -f \
  -l gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=eg \
  -c envoy

# 只看有 start_time 的访问行并格式化（需本机 jq）
kubectl -n envoy-gateway-system logs \
  -l gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=eg \
  -c envoy --tail=100 | grep start_time | jq
```

日志里重点字段：

| 字段 | 含义 |
|------|------|
| `route_name` | 命中的 HTTPRoute 规则 |
| `upstream_host` / `upstream_cluster` | 转到的后端 |
| `response_code` | 返回码 |
| `:authority` / `method` / `x-envoy-origin-path` | 请求 Host / 方法 / 路径 |

控制面排障（配置下发，不是每条业务请求）：

```bash
kubectl -n envoy-gateway-system logs -f deploy/envoy-gateway
```

默认访问日志打到 Envoy 容器 stdout；若要改格式或送到 Loki/OTel，在 `EnvoyProxy`（如 `eg-proxy`）里配 `spec.telemetry.accessLog`。

#### 6.1 让响应头返回 `x-request-id`（排障用）

访问日志里虽有 `x-request-id`，但 **Envoy 默认不会把它写回响应头**（客户端请求里没带时）。  
要用「响应头里的 ID → 搜日志」必须打开回写。

**临时验证（客户端自己带 ID）：**

```bash
RID=$(cat /proc/sys/kernel/random/uuid)   # 或 uuidgen
curl -sI -H "X-Request-ID: ${RID}" http://172.16.10.114:31258/ | grep -i x-request-id
# 响应里应能看到 x-request-id
```

**长期方案：强制始终回写（推荐）**

1. 开启 EnvoyPatchPolicy（改控制器配置后重启 `envoy-gateway`）：

```yaml
# EnvoyGateway / ConfigMap 配置片段
extensionApis:
  enableEnvoyPatchPolicy: true
  enableBackend: true   # HTTPRoute 用 Backend(FQDN) 时需要；空端点仍可用 BTP 自定义 503
```

常见改法（按实际安装调整）：

```bash
kubectl -n envoy-gateway-system edit configmap envoy-gateway-config
# 在 envoy-gateway.yaml 的 extensionApis 下加上 enableEnvoyPatchPolicy / enableBackend
kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway
```

2. 应用 patch：

```bash
kubectl apply -f examples/envoypatch-echo-request-id.yaml
```

核心是设置 HCM：`always_set_request_id_in_response: true`。  
同一份 patch 还会写 **`x-trace-id`**（32 位 hex，给 Tempo 搜）。须数据面已开 OTLP tracing，否则 `%TRACE_ID%` 为空。

3. 验证：

```bash
curl -sI http://172.16.10.114:31258/ | grep -iE 'x-request-id|x-trace-id'
# 期望:
#   x-request-id: <uuid>
#   x-trace-id: <32位hex>
# Tempo 用 x-trace-id 搜索
```

# 用该 ID 搜访问日志
kubectl -n envoy-gateway-system logs \
  -l gateway.envoyproxy.io/owning-gateway-name=eg -c envoy --tail=200 \
  | grep '<上面的-uuid>'
```

若 Gateway listener 不叫 `http` 或不在 `default`，改 YAML 里 `name: <ns>/<gateway>/<listener>`。
