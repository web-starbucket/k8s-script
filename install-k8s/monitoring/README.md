## Kubernetes 监控与日志

一体部署：**Prometheus + Grafana + Alertmanager**（指标）、**Loki + Promtail**（日志）、**Tempo**（链路追踪）。  
配置集中在 `config.yaml`，由 `install.sh` 串行安装（降低 etcd 压力）。

---

### 1. 架构

```text
  指标 ──► Prometheus ────────┐
  告警 ──► Alertmanager ──────┼──► Grafana ──► Dashboard / Explore
  日志 ──► Promtail ──► Loki ─┤
  追踪 ──► OTLP ──► Tempo ────┘
```

| 组件 | 作用 |
|------|------|
| Prometheus | 采集、存储指标 |
| Grafana | 可视化（指标 + 日志 + 追踪） |
| Alertmanager | 告警路由 |
| Loki | 日志存储与查询（默认保留 60 天，到期自动删） |
| Promtail | 各节点采集容器日志 |
| Tempo | 链路追踪存储与查询（默认保留 7 天） |

命名空间：`monitoring`

---

### 2. 目录文件

| 文件 | 说明 |
|------|------|
| `config.yaml` | **唯一业务配置**（NFS、镜像、端口、Helm values） |
| `install.sh` | 安装 / 升级 / 删除 / 重建 |
| `README.md` | 本文档 |
| `.generated/` | 脚本生成的临时清单（可忽略） |

---

### 3. 安装与卸载

#### 3.1 依赖

```bash
# 控制面可执行 kubectl / helm
helm version
kubectl get node

# 脚本依赖
apt-get install -y python3-yaml
# 或：pip3 install pyyaml
```

#### 3.2 NFS 准备（必做）

NFS 服务器：`172.16.10.120`（以 `config.yaml` 中 `nfs.server` 为准）

```bash
mkdir -p /data/nfs/shared/monitoring/{prometheus,grafana,alertmanager,loki,tempo}

chown -R 472:472     /data/nfs/shared/monitoring/grafana
chown -R 1000:2000   /data/nfs/shared/monitoring/prometheus
chown -R 1000:2000   /data/nfs/shared/monitoring/alertmanager
chown -R 10001:10001 /data/nfs/shared/monitoring/loki
chown -R 10001:10001 /data/nfs/shared/monitoring/tempo
```

| 目录 | 用途 | 属主 (UID:GID) |
|------|------|----------------|
| `.../grafana` | Grafana 数据 | 472:472 |
| `.../prometheus` | Prometheus 数据 | 1000:2000 |
| `.../alertmanager` | Alertmanager 数据 | 1000:2000 |
| `.../loki` | Loki 数据 | 10001:10001 |
| `.../tempo` | Tempo 追踪数据 | 10001:10001 |

> Loki 的 PVC 名固定为 **`storage-loki-0`**，Tempo 为 **`storage-tempo-0`**，由脚本预建并分别绑定 `pv-mon-loki` / `pv-mon-tempo`。路径以 `config.yaml` 的 `nfs.basePath` 为准。

#### 3.3 执行安装

```bash
cd /opt/service/k8s/monitoring   # 或本仓库 install-k8s-1.33/monitoring

bash install.sh              # 安装 / 升级
bash install.sh reinstall    # 全部删除后重建
bash install.sh destroy      # 仅删除
```

脚本特点：

- 串行操作、步骤间等待，减轻 etcd 超时  
- CRD 逐个 apply，Helm 失败自动重试  
- Loki / Tempo 先 0 副本，校正 PVC 后再拉起  
- node-exporter 强制使用 `v1.8.2`（禁止 `*-distroless`）
- Tempo liveness 使用 `/metrics`（不要用 `/ready`，避免 503 重启）

整次 `reinstall` 约 **15～30 分钟**，请勿中断。

#### 3.4 修改配置

只改 `config.yaml`，再执行：

```bash
bash install.sh
```

结构说明：

```yaml
nfs:               # NFS 地址与根路径
kubePrometheus:    # 指标栈 + Grafana（含 Loki / Tempo 数据源）
loki:              # 日志存储
tempo:             # 链路追踪（helm grafana/tempo）
promtail:          # 日志采集
```

---

### 4. 访问入口

先查 NodePort（以实际为准）：

```bash
kubectl -n monitoring get svc
```

| 服务 | 默认 NodePort | 地址示例 | 账号 |
|------|---------------|----------|------|
| Grafana | 30300 | `http://<节点IP>:30300` | admin / admin123456 |
| Prometheus | 30390 | `http://<节点IP>:30390` | - |
| Alertmanager | 30303 | `http://<节点IP>:30303` | - |

查 Grafana 密码：

```bash
kubectl -n monitoring get secret kube-prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

建议首次登录后修改密码。界面可设中文：**头像 → Profile → Language → 简体中文**（`config.yaml` 中已默认 `zh-Hans`）。

---

### 5. 使用 Grafana

#### 5.1 看指标（Prometheus）

1. 打开 Grafana  
2. 左侧 **Dashboards**，使用自带 Kubernetes / Node 等看板  
3. 或 **Explore** → 数据源选 **Prometheus** → 写 PromQL  

#### 5.2 看日志（Loki）

1. 左侧 **Explore**  
2. 右上角数据源选 **Loki**（不要选 Prometheus）  
3. 用 Label browser 选择 `namespace` / `pod` / `container`  
4. 示例查询：

```logql
{namespace="monitoring"}
```

```logql
{namespace="default"}
```

```logql
{namespace="default"} |= "error"
```

```logql
{pod=~"loki-.*"}
```

**历史日志与保留：**

- Grafana Explore 右上角改时间范围（如 Last 30 days / Absolute）即可查历史  
- Loki 默认保留 **1440h（60 天，约 2 个月）**，到期由 Compactor **自动删除**  
- 修改：`config.yaml` → `loki.loki.limits_config.retention_period`，再执行 `bash install.sh`  
- 磁盘约 50Gi；量很大时可加大 PVC / NFS，否则未到 60 天也可能写满  

**说明：**

- 只有产生过日志的 namespace 才会出现在标签列表里  
- `default` 若搜不到：先确认该命名空间有 Running 的 Pod，并放大时间范围（如 Last 24h）  
- 测试造日志：

```bash
kubectl -n default run log-test --image=busybox:1.36 --restart=Never \
  -- /bin/sh -c 'for i in 1 2 3 4 5; do echo hello-default-$i; sleep 1; done'
# Grafana 查询：{namespace="default"} |= "hello-default"
```

#### 5.3 看追踪（Tempo）

1. 左侧 **Explore** → 数据源选 **Tempo**（不要选 Loki）  
2. 时间范围用最近 15 分钟；界面若为 UTC，北京时间需减 8 小时  
3. Search 即可；OTLP 上报地址：`tempo.monitoring.svc.cluster.local:4317`（gRPC）  
4. Grafana 数据源 URL 必须是查询口 **3200**，不要填 4317  

Envoy Gateway 在 `EnvoyProxy` 里把 tracing 指到上述 4317 后，访问业务入口才会产生 span。

---

### 6. 日常运维命令

```bash
# 状态
kubectl -n monitoring get pod,svc,pvc
kubectl get pv | grep pv-mon
helm -n monitoring list

# 日志
kubectl -n monitoring logs -l app.kubernetes.io/name=grafana --tail=100
kubectl -n monitoring logs prometheus-monitoring-prometheus-0 -c prometheus --tail=100
kubectl -n monitoring logs loki-0 -c loki --tail=100
kubectl -n monitoring logs -l app.kubernetes.io/name=promtail --tail=50
kubectl -n monitoring logs -l app.kubernetes.io/name=tempo --tail=80

# 健康
curl -sS "http://<节点IP>:30390/-/healthy"
```

---

### 7. 镜像说明

内网优先使用私有仓 `registry.cn-chengdu.aliyuncs.com/obsbot/`（在 `config.yaml` 中配置）。

| 注意 | 说明 |
|------|------|
| node-exporter | 使用 `v1.8.2`，**不要**用 `*-distroless`（源上常没有） |
| Grafana + NFS | 关闭 `initChownData`，目录属主提前设为 472 |
| Prometheus 权限 | 数据目录必须 `1000:2000` |
| Loki 权限 | 数据目录必须 `10001:10001` |
| Tempo 权限 | 数据目录必须 `10001:10001` |

---

### 8. 常见问题

#### 8.1 Helm / etcd：`etcdserver: request timed out`

集群 API 压力过大。脚本已串行重试；若仍失败：

```bash
kubectl get --raw='/readyz?verbose' | head -30
# 确认 etcd、磁盘、内存正常后，再执行：
bash install.sh
```

#### 8.2 Pod Pending：`unbound PersistentVolumeClaims`

- 一块 PV 只能绑一个 PVC  
- Loki 必须使用已 Bound 的 **`storage-loki-0`**（50Gi / RWX）  
- 不要手建 `data-prometheus` 与 Operator PVC 抢同一块盘  

```bash
kubectl -n monitoring get pvc
kubectl get pv | grep pv-mon
```

#### 8.3 Prometheus Crash：`permission denied` / `queries.active`

```bash
# 在 NFS 服务器
chown -R 1000:2000 /data/nfs/monitoring/prometheus
rm -f /data/nfs/monitoring/prometheus/queries.active
kubectl -n monitoring delete pod prometheus-monitoring-prometheus-0 --force --grace-period=0
```

#### 8.4 Grafana Init：`chown: Operation not permitted`

NFS 不支持容器内 chown。保持 `initChownData.enabled: false`，并：

```bash
chown -R 472:472 /data/nfs/monitoring/grafana
```

#### 8.5 node-exporter ImagePullBackOff（`*-distroless`）

```bash
kubectl -n monitoring set image ds/kube-prometheus-prometheus-node-exporter \
  node-exporter=registry.cn-chengdu.aliyuncs.com/obsbot/node-exporter:v1.8.2
```

或重新执行 `bash install.sh`（脚本会强制校正）。

#### 8.6 Loki 一直 Pending / PVC 冲突

StatefulSet 会创建 `storage-loki-0`。错误的 `10Gi/RWO` PVC 需删掉重建。推荐：

```bash
bash install.sh reinstall
```

#### 8.7 Explore 里没有某个 namespace

该命名空间无 Pod 或尚无新日志时，Loki 不会出现对应 `namespace` 标签。用第 5.2 节方法造日志验证。

#### 8.8 Tempo Liveness 503 / 反复重启

Helm 默认 liveness 打 `/ready`，未就绪会 503 并被 kubelet 杀掉。脚本已改为 `/metrics`。NFS 目录需：

```bash
chown -R 10001:10001 /data/nfs/shared/monitoring/tempo
```

---

### 9. 验收清单

- [ ] `kubectl -n monitoring get pod` 主要组件 Ready  
- [ ] PVC 均为 Bound；`storage-loki-0` → `pv-mon-loki`，`storage-tempo-0` → `pv-mon-tempo`  
- [ ] Grafana 可登录  
- [ ] Dashboards 有节点/集群指标  
- [ ] Explore → Loki 可查 `{namespace="monitoring"}`  
- [ ] Explore → Tempo 能搜到最近 traces（需先有 OTLP 上报）  
- [ ] Prometheus `/healthy`、Alertmanager 页面可打开  

---

### 10. 快速参考

```bash
# 安装
bash install.sh

# 重建
bash install.sh reinstall

# 状态
kubectl -n monitoring get pod,svc,pvc

# Grafana 密码
kubectl -n monitoring get secret kube-prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

| 入口 | URL |
|------|-----|
| Grafana | `http://<节点IP>:30300` |
| Prometheus | `http://<节点IP>:30390` |
| Alertmanager | `http://<节点IP>:30303` |
| 查日志 | Grafana → Explore → **Loki** |
| 查追踪 | Grafana → Explore → **Tempo** |
