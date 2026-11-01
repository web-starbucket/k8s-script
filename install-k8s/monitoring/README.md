## Kubernetes 监控与日志（monitoring）

一体部署：**Prometheus + Grafana + Alertmanager**（指标）、**Loki + Alloy**（日志）、**Tempo**（链路追踪）。
配置集中在 `config.yaml`，由 `install.sh` 串行安装（降低 etcd 压力）。

```text
  指标 ──► Prometheus ────────┐
  告警 ──► Alertmanager ──────┼──► Grafana ──► Dashboard / Explore
  日志 ──► Alloy ──► Loki ────┤
  追踪 ──► OTLP ──► Tempo ────┘
```

命名空间：`monitoring`；存储默认 **Ceph RBD 动态供给**（可切 NFS）。

---

### 1. 组件一览

| 组件 | 作用 | 数据保留 | 存储 |
|------|------|---------|------|
| Prometheus | 采集、存储指标（全 namespace） | 15 天 | RBD 50Gi |
| Grafana | 可视化（指标 + 日志 + 追踪） | 永久 | RBD 50Gi |
| Alertmanager | 告警路由 | 永久 | RBD 50Gi |
| Loki | 日志存储与查询 | **90 天**，Compactor 到期自动删 | RBD 50Gi |
| Tempo | 链路追踪存储与查询 | 30 天 | RBD 50Gi |
| Alloy | 各节点采集容器日志（DaemonSet，Promtail 继任者） | - | - |
| node-exporter | 节点指标（DaemonSet） | - | - |

> RBD 为精简供给：50Gi 是配额上限，不写数据不占实际空间。扩容见 7.2。

版本钉版：kube-prometheus-stack chart **65.8.1**（operator v0.77.2）、Loki 3.3.2、Tempo 2.9.0、Alloy v1.21.3、node-exporter v1.8.2（禁用 `*-distroless`）。

---

### 2. 目录文件

| 文件 | 说明 |
|------|------|
| `config.yaml` | **唯一业务配置**（存储、镜像、端口、Helm values） |
| `install.sh` | 安装 / 升级 / 删除 / 重建 / 单装 Tempo |
| `README.md` | 本文档 |
| `.generated/` | 脚本生成的临时清单（勿手改，重跑即覆盖） |

`config.yaml` 结构：

```yaml
storage:           # 存储后端：type: ceph-rbd|nfs；storageClass；size 统一覆盖 5 个 PVC 容量
nfs:               # NFS 地址与根路径（storage.type=nfs 时生效）
kubePrometheus:    # 指标栈 + Grafana（含 Loki / Tempo 数据源）
loki:              # 日志存储（保留期 retention_period: 2160h）
tempo:             # 链路追踪（helm grafana/tempo）
alloy:             # 日志采集（helm grafana/alloy，River 配置在 alloy.alloy.configMap.content）
```

---

### 3. 安装

#### 3.1 前置条件

```bash
# 控制面可执行 kubectl / helm；脚本依赖 python3-yaml
helm version && kubectl get node
apt-get install -y python3-yaml   # 或 pip3 install pyyaml
```

**存储后端二选一：**

**A. ceph-rbd（默认，推荐）** — 前提（详见 ../install-ceph/README.md）：

1. Ceph 集群就绪，RBD 池 `kubernetes` 存在（`bootstrap → add-hosts → osd → pool`）
2. ceph1 执行 `sudo bash install-ceph.sh export-rbd` 生成 `csi/generated/`，在本集群 apply（ceph-csi 插件 + Secret）
3. `kubectl apply -f csi/storageclass-rbd.yaml`，`kubectl get sc ceph-rbd` 可见
4. 各 K8s 节点装挂载依赖：`apt install -y linux-modules-extra-$(uname -r) ceph-common && modprobe nbd`

**B. nfs（备选）** — 在 NFS 服务器建目录并授权：

```bash
mkdir -p /data/nfs/shared/monitoring/{prometheus,grafana,alertmanager,loki,tempo}
chown -R 472:472     /data/nfs/shared/monitoring/grafana
chown -R 1000:2000   /data/nfs/shared/monitoring/prometheus
chown -R 1000:2000   /data/nfs/shared/monitoring/alertmanager
chown -R 10001:10001 /data/nfs/shared/monitoring/loki
chown -R 10001:10001 /data/nfs/shared/monitoring/tempo
```

#### 3.2 存储配置（config.yaml → storage 段）

```yaml
storage:
  type: ceph-rbd        # ceph-rbd=动态供给（推荐）；nfs=静态 PV
  storageClass: ceph-rbd
  size: 50Gi            # 可选；统一覆盖 5 个组件的 PVC 容量
```

ceph-rbd 模式与 NFS 模式的差异：

- PVC 全部由 ceph-csi 动态供给（RWO），无需预建目录/chown（fsGroup 自动处理）
- **reclaimPolicy=Delete：`destroy` / `reinstall` 会把 RBD 里的数据一起删掉**，重要数据先备份
- RWO 单点挂载：本套组件均为单副本，重建时 CSI 自动 detach/attach
- 循环依赖提示：监控数据放在被监控的 Ceph 上，Ceph 整体故障时监控也不可用——建议给 Ceph 加外部探活

#### 3.3 执行安装

```bash
cd /opt/service/k8s/monitoring   # 或本仓库 install-k8s/monitoring

bash install.sh              # 安装 / 升级（全量）
bash install.sh tempo        # 只装 Tempo（用于先解决 x-trace-id；全量安装时会复用）
bash install.sh images       # 仅预拉镜像
bash install.sh reinstall    # 全部删除后重建（ceph-rbd 模式会删数据！）
bash install.sh destroy      # 仅删除（同上）
```

脚本特点：串行操作 + 步骤间等待（减轻 etcd 压力）；CRD 按内容筛选逐个 apply（兼容新旧 chart 结构）；Helm 失败自动重试；ceph-rbd 模式 Loki/Tempo 直接 1 副本安装（STS replicas=0 不会创建 PVC），nfs 模式走「先 0 副本校正 PVC 再拉起」。整次安装约 **15～30 分钟**，请勿中断。

#### 3.4 验收清单

- [ ] `kubectl -n monitoring get pod` 全部 Running/Ready
- [ ] `kubectl -n monitoring get pvc` 5 个 PVC 均 Bound（ceph-rbd）
- [ ] Grafana 可登录，Dashboards 有节点/集群指标
- [ ] Explore → Loki 可查 `{namespace="monitoring"}`
- [ ] Explore → Tempo 能搜到 traces（需先有 OTLP 上报，见 5.3）
- [ ] `curl -sS http://<节点IP>:30390/-/healthy` 返回 ok

---

### 4. 访问入口

| 服务 | 地址 | 账号 |
|------|------|------|
| Grafana | `http://<节点IP>:30300` | admin / admin123456 |
| Prometheus | `http://<节点IP>:30390` | - |
| Alertmanager | `http://<节点IP>:30303` | - |

```bash
# 查 Grafana 密码
kubectl -n monitoring get secret kube-prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

界面默认中文（`default_language: zh-Hans`）。首次登录建议改密码。

---

### 5. 日常使用

#### 5.1 看指标（Prometheus）

左侧 **Dashboards** 用自带 Kubernetes/Node 看板；或 **Explore** → 数据源 **Prometheus** 写 PromQL。

#### 5.2 看日志（Loki）

**Explore** → 数据源选 **Loki**，用 LogQL 查询：

| 需求 | LogQL |
|------|-------|
| 某 namespace | `{namespace="dev"}` |
| 某 Pod / 容器 | `{namespace="dev", pod=~"myapp-.*"}` / `{namespace="dev", container="myapp"}` |
| 内容过滤 | `{namespace="dev"} \|= "error"`（排除用 `!=`，正则用 `\|~`） |
| 统计错误数 | `sum by (namespace) (count_over_time({namespace="prod"} \|~ "(?i)error\|exception"[5m]))` |

- 输入 `{` 后 Grafana 自动补全可用标签：`namespace` / `pod` / `container` / `app` / `node`
- **实时日志**：查询后点右上角 **Live** 按钮 = `tail -f`（有数秒采集延迟）
- 历史：右上角改时间范围；保留 **90 天**，到期自动删
- 只有产生过日志的 namespace 才出现在标签列表里；搜不到先确认有 Running Pod 并放大时间范围

命令行应急（不经过 Loki）：

```bash
kubectl -n dev logs -f -l app=myapp --tail=20      # 按 label 实时跟随
kubectl -n dev logs myapp-xxx --previous           # 崩溃前的日志（排 CrashLoop）
```

测试造日志：

```bash
kubectl -n default run logtest --rm -i \
  --image=registry.cn-global.starbucket.com.cn/starbucket/docker.io/library/busybox:1.36.1 \
  -- sh -c 'echo hello-loki-test'
# Grafana 查：{namespace="default"} |= "hello-loki-test"
```

#### 5.3 看追踪（Tempo）

- **Explore** → 数据源 **Tempo** → 按 trace id 反查（如网关响应头里的 `x-trace-id`）
- span 详情里点 **Logs for this span** 直接跳到该 trace 时间窗的相关日志（已预配 tracesToLogs）
- OTLP 上报地址：`tempo.monitoring.svc.cluster.local:4317`（gRPC）/ `:4318`（HTTP）
- Grafana 数据源 URL 是查询口 **3200**，不要填 4317
- **Envoy Gateway 联动**：`EnvoyProxy` 的 `telemetry.tracing` 指向 4317 后 `%TRACE_ID%` 才有值（x-trace-id 响应头依赖它，见 ../gateway-api/eg-proxy.yaml）

#### 5.4 告警（Alertmanager）

默认告警规则已加载（节点/集群级）。接收通知需在业务 namespace 建 `AlertmanagerConfig`（见第 6 节），或改 `config.yaml` 的 alertmanager 段配置全局 receiver。

---

### 6. 新增业务分区（dev/test/prod）接入

Prometheus 已配置为采集**所有 namespace**（选择器全放开）。新业务分区**不需要改监控配置**，在分区自己的 namespace 里声明资源即可：

```yaml
# 示例：dev 分区的 myapp 指标采集
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: dev
spec:
  selector:
    matchLabels:
      app: myapp          # 匹配业务 Service 的 label
  endpoints:
    - port: metrics       # Service 上的端口名
      interval: 30s
```

| 需求 | 在业务 namespace 建什么 |
|------|------------------------|
| 指标采集（有 Service） | `ServiceMonitor` |
| 指标采集（无 Service） | `PodMonitor` |
| 告警规则 | `PrometheusRule`（自动加载，告警自带 `namespace` 标签） |
| 告警路由/接收人 | `AlertmanagerConfig`（按 namespace 分流到不同接收器） |
| 日志 | 无需配置——Alloy 采所有节点容器日志，用 `{namespace="dev"}` 过滤 |
| 链路追踪 | 应用 OTLP 指向 `tempo.monitoring.svc.cluster.local:4317` / `:4318` |

---

### 7. 运维操作

#### 7.1 修改配置

只改 `config.yaml`，再执行 `bash install.sh`（幂等）。

#### 7.2 PVC 在线扩容（只增不减）

`ceph-rbd` 已开 `allowVolumeExpansion: true`，patch 即扩，**无需重启 Pod**：

```bash
# 例：loki 50Gi → 100Gi
kubectl -n monitoring patch pvc storage-loki-0 \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

kubectl -n monitoring get pvc storage-loki-0 -w        # CAPACITY 变新值即完成
kubectl -n monitoring exec loki-0 -- df -h /var/loki   # ext4 自动在线扩
```

- Ceph 侧无需任何操作（扩的是配额）；扩完同步改大 `config.yaml` 的 `storage.size`
- **注意**：loki/tempo 的 size 变化会让 helm 升级撞 STS `volumeClaimTemplates` immutable 报错；此时 `kubectl -n monitoring delete sts loki tempo --cascade=orphan` 再重跑 `install.sh`（Pod 重建、PVC 沿用、数据不丢）。Prometheus/Alertmanager 由 operator 管理 PVC，无此问题

#### 7.3 镜像与版本

- 所有镜像走 `registry.cn-global.starbucket.com.cn/starbucket/<原仓库>/<路径>:<tag>`
- 换版本前先探测 starbucket 是否有该 tag（返回 200 才能用）：

```bash
REPO=starbucket/docker.io/grafana/alloy; TAG=v1.21.3
TOKEN=$(curl -s "https://registry.cn-global.starbucket.com.cn/service/token?service=harbor-registry&scope=repository:${REPO}:pull" | jq -r .token)
curl -sI -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "https://registry.cn-global.starbucket.com.cn/v2/${REPO}/manifests/${TAG}"
```

- kube-prometheus-stack chart 钉在 **65.8.1**（env `KPS_CHART_VERSION` 可覆盖）；chart 与 operator 镜像需配套升级
- node-exporter 强制 `v1.8.2`，禁用 `*-distroless`（脚本自动校正）

#### 7.4 卸载与数据

```bash
bash install.sh destroy      # ceph-rbd 模式：PVC 删除后 RBD 数据不可恢复！
```

NFS 模式的 PV 是 `Retain`，destroy 后数据仍在 NFS 目录。

---

### 8. 故障排查

| 症状 | 原因与处理 |
|------|-----------|
| PVC 一直 Pending | `kubectl describe pvc <名>` 看事件；依次确认：`kubectl get sc ceph-rbd` 存在、`kubectl -n ceph-csi get secret csi-rbd-secret` 已 apply、ceph-csi provisioner 日志、Ceph 侧 `ceph osd pool ls` 有 `kubernetes` 池、节点到 MON 6789 通 |
| `storageclass.storage.k8s.io "ceph-rbd" not found` | 漏了 `kubectl apply -f csi/storageclass-rbd.yaml` |
| Pod 挂卷失败 `rbd map` / 524 | 节点缺 nbd 模块：`apt install -y linux-modules-extra-$(uname -r) ceph-common && modprobe nbd` |
| Grafana `Multi-Attach error` | RWO 卷滚动更新双挂；已内置 `deploymentStrategy: Recreate` 修复，老存量删旧 Pod 即可 |
| ImagePullBackOff | 镜像在 starbucket 上不存在（404）；用 7.3 的探测命令确认，缺的推上去或换已有 tag |
| `install.sh: step: command not found` | 旧版 bug，同步最新 install.sh |
| Tempo 启动期 readiness 503 | 正常：WAL 回放 + ingester 注册 ring 需 1~2 分钟，`/ready` 就绪前不接流量。超 5 分钟才需查 |
| Tempo 日志刷 `GET /metrics broken pipe` | 旧版 HTTP 探针噪音；已改 TCP 探针（tcpSocket:3200），重跑 install.sh 生效 |
| `etcdserver: request timed out` | API 压力过大；脚本已串行+重试，确认 etcd/磁盘/内存正常后重跑 `bash install.sh` |
| Prometheus Crash `permission denied`（仅 NFS 模式） | NFS 目录属主错：`chown -R 1000:2000 .../prometheus`，删 `queries.active` 后重启 Pod |
| Grafana init `chown: Operation not permitted`（仅 NFS 模式） | NFS 不支持容器内 chown；保持 `initChownData.enabled: false` 并预 chown 472:472 |
| x-trace-id 响应头为空 | EG 未开 tracing：apply `../gateway-api/eg-proxy.yaml`（telemetry.tracing → tempo:4317）+ `examples/envoypatch-echo-request-id.yaml`；patch Programmed=False 报 `unknown field "mutations"` 是 http_filters 下标打错（见该文件头注释） |

常用排查命令：

```bash
kubectl -n monitoring get pod,svc,pvc
helm -n monitoring list
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=50
kubectl -n monitoring logs loki-0 --tail=50
kubectl -n ceph-csi logs deploy/ceph-csi-rbd-provisioner -c csi-provisioner --tail=30   # 看 leader Pod 的
```

---

### 9. 快速参考

```bash
bash install.sh                 # 安装 / 升级
bash install.sh tempo           # 只装 Tempo
bash install.sh reinstall       # 重建（ceph-rbd 会删数据！）
kubectl -n monitoring get pod,svc,pvc
```

| 入口 | 地址 |
|------|------|
| Grafana | `http://<节点IP>:30300`（admin / admin123456） |
| Prometheus | `http://<节点IP>:30390` |
| Alertmanager | `http://<节点IP>:30303` |
| 查日志 | Grafana → Explore → **Loki**（Live 按钮实时跟踪） |
| 查追踪 | Grafana → Explore → **Tempo**（用 x-trace-id 反查） |
| OTLP | `tempo.monitoring.svc.cluster.local:4317`（gRPC）/ `:4318`（HTTP） |
