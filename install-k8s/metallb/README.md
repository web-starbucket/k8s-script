## MetalLB（L2）— 给裸机 K8s 分配局域网 VIP

kubeadm 装的集群**没有云厂商 LoadBalancer**，`type: LoadBalancer` 的 Service 会永远停在 `EXTERNAL-IP=<pending>`。MetalLB 用一个局域网地址池补上这块：L2 模式下由 `speaker` 选举出**一个节点**发免费 ARP（IPv6 为 NDP）把 VIP 宣告到二层网络，流量到该节点后再由 Envoy / kube-proxy 转进 Pod。

本目录只做一件事：装好 MetalLB + 一个 `172.16.10.250/32` 的 L2 地址池，供 `../gateway-api` 把 Envoy 数据面从 NodePort 改成 LoadBalancer（对外 80/443）。

官方项目：[metallb/metallb](https://github.com/metallb/metallb) · 本目录版本 **v0.14.9**（`metallb-native.yaml`，非 Helm）

---

### 文件一览

| 文件 | 作用 |
|------|------|
| `install-metallb.sh` | 下载并 apply `metallb-native.yaml`（v0.14.9），等 `controller` / `speaker` 就绪，再 apply `ipaddresspool.yaml` |
| `ipaddresspool.yaml` | `IPAddressPool/lan-pool`（`172.16.10.250/32`）+ `L2Advertisement/lan-l2` |
| `diagnose-metallb-lb.sh` | EXTERNAL-IP 一直 pending 时的一键排查（含独立测试 Service，用完自动删） |

配套文件在 `../gateway-api/`（不在本目录）：

| 文件 | 作用 |
|------|------|
| `eg-proxy-loadbalancer.yaml` | `EnvoyProxy/eg-proxy` 数据面改 `LoadBalancer` + VIP annotation |
| `ensure-envoy-loadbalancer.sh` | NodePort → LoadBalancer，等待 EXTERNAL-IP（会预检本目录的 MetalLB） |
| `ensure-envoy-nodeport.sh` | 改回 NodePort；**卸载 MetalLB 前先执行** |

---

### IP 规划（改地址前先看这里）

| IP | 用途 | 出处 |
|----|------|------|
| `172.16.10.100` | kube-apiserver VIP（Keepalived + HAProxy `:8443`）**不可占用** | `../k8s-nodes.conf` |
| `172.16.10.114~117` | Master / Worker 节点真实 IP | `../k8s-nodes.conf` |
| `172.16.10.250` | **MetalLB L2 VIP**，入口 80/443 | `ipaddresspool.yaml` |

同一个 VIP 只由**一个**节点持有；`kubectl get pods -o wide` 看到持有节点发生切换是正常的（故障重新选举），不是异常。

---

### 前提

- Kubernetes 1.33 集群已就绪：`kubectl get nodes` 全 Ready，CNI（Calico）已装
- 客户端与节点在**同一二层网络**（L2 模式的硬性要求；跨网段请改 BGP）
- 已规划一个**未被占用**的局域网 IP（默认 `172.16.10.250`），`ping` 不通才可用
- 节点能访问 `raw.githubusercontent.com`（直连或经 `GH_PROXY`）
- 当前用户有 kubectl 管理员权限（脚本本身不需要 `sudo`）
- `speaker` 需要 `hostNetwork` + `privileged`；若给 `metallb-system` 启用了 `restricted` PSA，先放开：

```bash
kubectl label ns metallb-system pod-security.kubernetes.io/enforce=privileged --overwrite
```

---

### 快速开始

```bash
cd /opt/k8s-script/install-k8s/metallb

# 1) 装 MetalLB + 地址池（脚本用 SCRIPT_DIR 定位 yaml，可在任意目录执行）
bash install-metallb.sh

# 2) 让 Gateway 数据面用上 VIP（Gateway 不存在时先 apply examples/gateway-http.yaml）
cd ../gateway-api
kubectl apply -f examples/gateway-http.yaml
bash ensure-envoy-loadbalancer.sh

# 3) 验证
curl -sI http://172.16.10.250/
```

域名把 A 记录指到 `172.16.10.250` 即可直接用 80/443。`PORT(S)` 里仍会带一个 NodePort，那是 LoadBalancer 的正常附带端口，不用管。

安装脚本是幂等的（`kubectl apply` + `wait`），中断后重跑即可。其中 `speaker` 的 `wait` 带 `|| true`，不会因个别节点慢而中断整个流程。

---

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `METALLB_VERSION` | `v0.14.9` | 只影响 `install-metallb.sh` 下载的 manifest 版本 |
| `GH_PROXY` | `https://ghfast.top/` | `raw.githubusercontent.com` 前缀代理，可换 `https://gh-proxy.com/` 等 |
| `LB_IP` | `172.16.10.250` | `diagnose-metallb-lb.sh` / `ensure-envoy-loadbalancer.sh` 用的 VIP（写入 annotation 与测试 Service） |

```bash
METALLB_VERSION=v0.14.9 GH_PROXY=https://gh-proxy.com/ bash install-metallb.sh
```

注意 `GH_PROXY` 用的是 `${GH_PROXY:-默认值}`，**置空会回落到默认代理**，不能用空值直连；要直连或离线请按第 5 节「离线 / 手动下载」处理。

---

### 1. 验证安装

```bash
kubectl -n metallb-system get pods -o wide
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o wide
```

期望：

```text
controller-xxx   1/1  Running
speaker-xxx      1/1  Running   ← 每个节点一个
NAME          AGE
lan-pool      ...
lan-l2        ...
TYPE=LoadBalancer  EXTERNAL-IP=172.16.10.250  PORT(S)=80:3xxxx/TCP,443:3xxxx/TCP
```

再确认二层宣告生效（在**局域网内任意主机**上执行）：

```bash
ping -c2 172.16.10.250
arping -I <你的网卡> 172.16.10.250   # 能看到某个节点 MAC 应答
curl -sI http://172.16.10.250/
```

---

### 2. 改 VIP / 扩地址池

改 VIP 要**同时**改三处为同一个 IP，否则要么分配失败，要么分到池外地址：

1. `ipaddresspool.yaml` 的 `spec.addresses`
2. `../gateway-api/eg-proxy-loadbalancer.yaml` 的 annotation `metallb.universe.tf/loadBalancerIPs`
3. 环境变量 `LB_IP`（跑 `ensure-envoy-loadbalancer.sh` / `diagnose-metallb-lb.sh` 时传）

```bash
LB_IP=172.16.10.201 bash ../gateway-api/ensure-envoy-loadbalancer.sh
```

需要多个 VIP（多个 Gateway / 多个业务入口）时，把池改成区间，并各自用 annotation 指定：

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.16.10.250-172.16.10.254
  # 只允许通过 annotation 显式指定 IP 时打开（不给自动分配）
  # autoAssign: false
```

改完生效：

```bash
kubectl apply -f ipaddresspool.yaml
LB_IP=172.16.10.201 bash ../gateway-api/ensure-envoy-loadbalancer.sh
```

`ensure-envoy-loadbalancer.sh` 发现当前 `EXTERNAL-IP ≠ LB_IP` 时会**删除数据面 Service 让 Envoy Gateway 重建**（旧 IP 已不在新池内，speaker 会拒绝配置），期间入口有秒级中断。

---

### 3. 排查：`diagnose-metallb-lb.sh`

```bash
# 默认排查 Service: envoy-gateway-system/envoy-default-eg-e41e7b31
bash diagnose-metallb-lb.sh

# 换成你真实的数据面 Service 名
bash diagnose-metallb-lb.sh envoy-default-eg-xxxxxxxx

# 改过 VIP 时一起传
LB_IP=172.16.10.201 bash diagnose-metallb-lb.sh
```

先查 Service 名：

```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg
```

脚本分 6 段输出：

| 段 | 看什么 |
|----|--------|
| `MetalLB` | `controller` / `speaker` 是否 Running；`ipaddresspool` / `l2advertisement` 是否存在；集群有没有 `LoadBalancerClass` CR |
| `EnvoyProxy CR` | `eg-proxy` 的 `envoyService` 是否 `LoadBalancer` + 是否带 VIP annotation |
| `数据面 Service` | `type` / `loadBalancerClass` / `loadBalancerIP` / annotation / `EXTERNAL-IP` 五个字段一次打全 |
| `controller 日志` | 最近 30 行，分配失败的原因通常直接写在这里 |
| `独立测试 Service` | 在 `default` 建 `metallb-lb-test`（端口 18080，selector 故意指向不存在的 Pod）验证 MetalLB 本身能否分配 `LB_IP`，等 15s 判定后**自动删除** |
| `网络` | `ping LB_IP`：ping 通 = 可能被别的主机占用（IP 冲突）；ping 不通 = 正常（尚未宣告或未被占用） |

结论解读：

| 输出 | 含义 | 下一步 |
|------|------|--------|
| `✅ MetalLB 可分配 IP` | MetalLB 与地址池都正常 | 问题在 Envoy 数据面 Service，最常见是 `loadBalancerClass`，按提示删 svc 重建 |
| `❌ 测试 Service 也 pending` | MetalLB 本身有问题 | 看 controller 日志、池地址、speaker 状态（下表） |

> 独立测试 Service 只验证“能否分配 IP”，selector 指向不存在的 Pod，因此**分配成功但 curl 不通是正常的**；连通性要用真实数据面 Service 验。

---

### 4. 常见故障对照

| 现象 | 原因 | 处理 |
|------|------|------|
| `EXTERNAL-IP` 一直 `<pending>`，Service 上有 `loadBalancerClass` | MetalLB v0.14 原生 manifest **没有** `LoadBalancerClass` CR；该字段 K8s 也**不允许事后修改** | apply 不带该字段的 `eg-proxy-loadbalancer.yaml`，再 `kubectl -n envoy-gateway-system delete svc <name>` 让 EG 重建（`ensure-envoy-loadbalancer.sh` 会自动做） |
| `pending`，controller 日志报分配冲突 | 同时写了 `spec.loadBalancerIP` 与 annotation `metallb.universe.tf/loadBalancerIPs` | 只保留 annotation；`ensure-envoy-loadbalancer.sh` 检测到 `spec.loadBalancerIP` 会主动移除 |
| `pending`，日志提示地址不在池内 | 改了 VIP 没重新 apply `ipaddresspool.yaml`，或 annotation 与池不一致 | `kubectl apply -f ipaddresspool.yaml` 后重跑 `ensure-envoy-loadbalancer.sh` |
| 分到 IP 但 `curl` 不通 | IP 与局域网已有主机冲突；交换机过滤免费 ARP；节点防火墙拦截；客户端不在同一二层 | `ping` / `arping` 确认占用与宣告；检查节点 `iptables`、云主机安全组；确认客户端与节点同网段 |
| 只有部分节点能通 VIP | L2 模式下 VIP 只挂在一个节点（正常） | 若要求多点宣告 / ECMP，需改用 BGP 模式 |
| `speaker` Pod 起不来（`CreateContainerConfigError` / 被驱逐） | PSA `restricted` 拦截 `privileged` / `hostNetwork` | `kubectl label ns metallb-system pod-security.kubernetes.io/enforce=privileged --overwrite`，再 `kubectl -n metallb-system rollout restart ds/speaker` |
| `install-metallb.sh` 在 `curl` 阶段失败 | 节点出不了网 / 代理不可用 | 换 `GH_PROXY`，或按第 5 节「离线 / 手动下载」离线 apply |
| `wait` 超时但 Pod 最终正常 | 镜像拉取慢（`quay.io/metallb/*`） | 重跑 `bash install-metallb.sh`；或先把镜像同步到私有仓 |
| 日志出现 `etcdserver: request timed out` | 集群 etcd 压力大 | 等 `kubectl get --raw=/readyz` 返回 ok 后重跑 |

```bash
# 手工排查四件套
kubectl -n metallb-system logs deploy/controller --tail=40
kubectl -n metallb-system logs ds/speaker --tail=20
kubectl -n envoy-gateway-system describe svc <svc-name> | tail -20
kubectl -n envoy-gateway-system get svc <svc-name> -o yaml | grep -E 'loadBalancerClass|loadBalancerIP|metallb'
```

---

### 5. 离线 / 手动下载

`install-metallb.sh` 的下载地址（`GH_PROXY` 拼接后）：

```text
${GH_PROXY}https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

有网机器下载，传到集群节点后手动 apply：

```bash
curl -fL -o metallb-native.yaml \
  "https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml"

# 节点上
kubectl apply -f metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=180s
kubectl apply -f ipaddresspool.yaml
```

用私有镜像仓时，先把 manifest 里的两个镜像替换掉再 apply：

```bash
sed -i 's#quay.io/metallb/#registry.example.com/myproj/metallb/#g' metallb-native.yaml
grep -n 'image:' metallb-native.yaml   # controller:v0.14.9 / speaker:v0.14.9
```

---

### 6. L2 与 BGP（本目录用 L2）

| 模式 | 说明 | 本目录 |
|------|------|--------|
| **L2** | 免费 ARP / NDP 宣告 VIP，**不需要**路由器或交换机配合；同一时刻只有一个节点持有 VIP，故障切换靠重新选举（秒级） | ✅ 默认，`L2Advertisement/lan-l2` |
| BGP | 与上联交换机建 BGP 会话，可多点宣告 / ECMP，切换更快；需要网络设备支持并规划 ASN、Peer 地址 | ❌ 未使用（需自建 `BGPPeer` 并换 `BGPAdvertisement`） |

L2 的取舍：客户端必须与节点在同一二层；持有 VIP 的节点宕机时，会有几秒 ARP 收敛窗口。

---

### 7. 卸载

本目录没有 uninstall 脚本，按顺序手动执行（**先把入口改回 NodePort**，否则删掉 MetalLB 后 `EXTERNAL-IP` 会消失、入口直接不可用）：

```bash
# 1) 数据面回到 NodePort
cd /opt/k8s-script/install-k8s/gateway-api
bash ensure-envoy-nodeport.sh

# 2) 删 MetalLB（清单 + 地址池）
cd ../metallb
export GH_PROXY="${GH_PROXY:-https://ghfast.top/}"
curl -fL -o /tmp/metallb-native.yaml \
  "${GH_PROXY}https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml"
kubectl delete -f /tmp/metallb-native.yaml --ignore-not-found
kubectl delete -f ipaddresspool.yaml --ignore-not-found

# 3) 自检（应无输出）
kubectl get ns metallb-system
kubectl get crd | grep metallb
```

命名空间卡在 `Terminating` 时清 finalizers（与本仓库其他卸载脚本同一手法）：

```bash
kubectl get ns metallb-system -o json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);d["spec"]["finalizers"]=[];print(json.dumps(d))' \
  | kubectl replace --raw "/api/v1/namespaces/metallb-system/finalize" -f -
```

重装：`bash install-metallb.sh` → `bash ../gateway-api/ensure-envoy-loadbalancer.sh`。

---

### 不要做的事

- 不要把 `172.16.10.100`（kube-apiserver Keepalived VIP）放进地址池，也不要用节点真实 IP `.114~.117`
- 不要同时写 `spec.loadBalancerIP`（K8s 1.24 起已废弃）和 annotation `metallb.universe.tf/loadBalancerIPs`
- 不要给 Service 加 `loadBalancerClass: metallb`（v0.14 原生 manifest 无此 CR，会永远 pending 且该字段不可事后修改）
- 不要选局域网内已被占用的 IP；改 IP 前先 `ping` 确认不通
- 不要在客户端与节点跨二层网络时期望 L2 生效（要么同网段，要么改 BGP）
- 不要在数据面仍是 LoadBalancer 时直接删 MetalLB（先 `ensure-envoy-nodeport.sh`）
- 不要用 shell 里未赋值的 `${METALLB_VERSION}` 手敲 curl（会 404）；版本写在脚本里，覆盖时用 `METALLB_VERSION=vX.Y.Z bash install-metallb.sh`

---

### 相关目录

| 目录 | 关系 |
|------|------|
| `../` | `install-k8s.sh` 建集群、`k8s-nodes.conf` 节点与 VIP 规划 |
| `../gateway-api` | 入口网关；用本目录的 VIP 把数据面改成 LoadBalancer |
| `../monitoring` | Prometheus + Grafana + Loki + Tempo，可监控 MetalLB 与数据面 |
