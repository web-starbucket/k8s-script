## 独立 Ceph 集群（cephadm + RBD）

与业务 Kubernetes **分开部署**：本目录装在 **至少 3 台专用存储机** 上，不占用 K8s Master/Worker。  
业务集群只当客户端：装 Ceph CSI 后用 `StorageClass ceph-rbd` 动态开块设备（适合 Postgres 等）。

Ubuntu 24 · `cephadm` · 默认发行版 **reef（18.2）** · 三副本 RBD 池 `kubernetes`

---

### 1. 架构

```text
ceph1 (bootstrap / MON / MGR / OSD)
ceph2 (MON / OSD)
ceph3 (MON / OSD)
        │  OTLP 不走这里；RBD 走 MON:6789 + OSD 6800-7300
        ▼
业务 K8s Worker  ── Ceph CSI RBD ──► PVC / Postgres
```

| 组件 | 作用 |
|------|------|
| MON | 法定人数，生产 3 个 |
| MGR | Dashboard / 编排 |
| OSD | 数据盘，每台至少 1 块**独立空盘** |
| RBD | 块设备；CSI 供给 PVC |

不要把 OSD 打在 K8s 控制面或系统盘上。

---

### 2. 目录

| 文件 | 说明 |
|------|------|
| `ceph-nodes.conf` | 版本、RBD 池、节点 IP / 密码 / OSD 盘 |
| `install-ceph.sh` | 安装与运维 |
| `csi/storageclass-rbd.yaml` | 业务集群 StorageClass |
| `csi/secret.yaml.example` | CSI 模板；**monitors 从 `ceph-nodes.conf` 生成**（`csi-example` / `export-rbd`） |
| `csi/generated/` | `export-rbd` 写出的真实密钥（已 gitignore） |

---

### 3. 硬件与网络

- **节点**：≥ 3 台，建议同规格；与 K8s 节点 IP 分段或至少别混角色
- **磁盘**：第 6 列填写的设备必须是空盘（`lsblk` 确认无分区、无系统）。脚本会交给 cephadm 做成 OSD，**数据会清空**
- **端口**（节点之间 + 业务 Worker → Ceph）：`3300`、`6789`、`6800-7300`、Dashboard `8443`
- **时间**：prepare 会开 chrony；时钟差大会导致 MON 异常

示例 `ceph-nodes.conf`（改成真实 IP / 密码 / 盘符）：

```text
CEPH_RELEASE=reef
RBD_POOL=kubernetes

172.16.10.131|ceph1|bootstrap|root|你的密码|/dev/sdb
172.16.10.132|ceph2|node|root|你的密码|/dev/sdb
172.16.10.133|ceph3|node|root|你的密码|/dev/sdb
```

`bootstrap` 只能有一行，且 **bootstrap / add-hosts / osd / pool / export-rbd 都在这台执行**。

国内拉包可在 conf 打开：

```text
CEPH_APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ceph/debian-reef
```

---

### 4. 安装顺序

在 **bootstrap 节点**（ceph1）上操作；先把本目录拷过去或从 git 拉取。

```text
改 conf → 全员 prepare → ssh-keys → hosts-all
→ bootstrap → add-hosts → osd → pool → status
```

`prepare` / `prepare-all` / `bootstrap` 开始时会打印本部署要拉的镜像；也可单独查看：

```bash
bash install-ceph.sh images
```

默认（reef）包括 `quay.io/ceph/ceph:v18` 以及 cephadm 监控栈（Prometheus / Alertmanager / node-exporter / Grafana）。已有业务监控时在 conf 设 `SKIP_MONITORING_STACK=1`。

```bash
chmod +x install-ceph.sh
chmod 600 ceph-nodes.conf

# 本机（ceph1）先能 SSH 到另外两台后：
sudo bash install-ceph.sh ssh-keys
sudo bash install-ceph.sh prepare-all
sudo bash install-ceph.sh hosts-all

sudo bash install-ceph.sh bootstrap
sudo bash install-ceph.sh add-hosts
sudo bash install-ceph.sh osd
sudo bash install-ceph.sh pool
sudo bash install-ceph.sh status
```

单机调试可在每台先跑 `sudo bash install-ceph.sh prepare`，再在 ceph1 上 `ssh-keys` 与后续命令。

`HEALTH_OK`、3 个 OSD `up`、池 `kubernetes` 存在即完成。

Dashboard：`https://<ceph1>:8443` ，用户 `admin`。密码见 bootstrap 输出，或：

```bash
ceph dashboard ac-user-show admin
```

---

### 5. OSD 注意

- 默认**只使用 conf 第 6 列**，例如 `/dev/sdb` 或 `/dev/sdb,/dev/sdc`
- 不要对系统盘、有数据的盘执行 `osd`
- 若确有多块空闲盘要全部交给 Ceph：conf 设 `OSD_ALLOW_ALL=1`，再：

```bash
sudo bash install-ceph.sh osd --all-available-devices
```

---

### 6. 扩容与缩容

Ceph **不会**按负载自动加减节点（不像 K8s HPA）。扩缩是运维操作：加盘/加机会触发数据再平衡；缩容必须先把 OSD 上的数据迁走。  
业务 PVC 变大走 StorageClass 扩容，和本节「加减存储机」不是一回事。

所有命令默认在 **ceph1（bootstrap）** 上执行。OSD 只能用**独立空盘**（`lsblk` 无挂载），禁止系统盘（`vda` / `sda` 上的 `/`）。

#### 6.1 扩容：只加盘（同一台已有节点）

新盘挂到 ceph1/2/3 之一后：

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT   # 确认新盘如 /dev/vdb，无 MOUNTPOINT
```

改 `ceph-nodes.conf` 该节点第 6 列（多块盘逗号分隔）：

```text
172.16.10.131|ceph1|bootstrap|root|你的密码|/dev/vdb,/dev/vdc
```

```bash
sudo bash install-ceph.sh osd
ceph -s          # 等到 HEALTH_OK，无 recovery / backfill 再视为完成
ceph osd tree
```

#### 6.2 扩容：加一台存储机

新机同样要有系统盘 + **一块空数据盘**。角色用 `node`（`bootstrap` 只能有一行）。

1. 在 `ceph-nodes.conf` 追加，例如：

```text
172.16.10.134|ceph4|node|root|你的密码|/dev/vdb
```

盘符以**新机**上 `lsblk` 为准（虚拟机常见 `/dev/vdb`，不是 `/dev/sdb`）。

2. 在 ceph1 上：

```bash
sudo bash install-ceph.sh ssh-keys
sudo bash install-ceph.sh hosts-all
sudo bash install-ceph.sh prepare-all
sudo bash install-ceph.sh add-hosts
sudo bash install-ceph.sh osd
sudo bash install-ceph.sh status
```

`add-hosts` 把 conf 里尚未加入的主机 `ceph orch host add`；`osd` 按第 6 列建 OSD。集群会自动把部分 PG 迁到新 OSD。

3. 确认完成：

```bash
ceph -s              # HEALTH_OK，无 recovery / backfill
ceph orch host ls
ceph osd tree        # 新主机上有 OSD 且 up
```

MON 保持 **奇数**。三台够用就不要加 MON；若要 5 个 MON：

```bash
ceph orch apply mon --placement="ceph1,ceph2,ceph3,ceph4,ceph5"
```

容量不够时：**先加盘，再加人。** 不要按 `ceph df` 水位自动删节点。

#### 6.3 缩容：下线一台（须手工，脚本无 remove-host）

**三节点集群不要缩到 2 台**（MON 不够票会停写；`size=3` 也无法放三副本）。最小生产规模就是 3 台。

假设去掉 `ceph4`，OSD id 以 `ceph osd tree` 为准：

```bash
ceph osd tree
# 可选：先把权重打到 0，搬数据更温和
# ceph osd crush reweight osd.<id> 0

ceph orch osd rm <id> --zap          # 可对多个 id 各执行一次
ceph -s                              # 等到无 recovery，该 OSD 从 tree 消失

ceph orch host drain ceph4
ceph orch host rm ceph4              # 确认该机已无 OSD 后再删
# 节点已关机且确认无数据：ceph orch host rm ceph4 --offline
```

然后从 `ceph-nodes.conf` 删除对应行，并 `sudo bash install-ceph.sh hosts-all` 刷新 hosts。

#### 6.4 不要自动做的事

| 做法 | 说明 |
|------|------|
| 按 CPU/磁盘使用率自动加虚拟机 | rebalance 会打满网络和 OSD，容易拖垮现网 |
| 按水位自动 `host rm` | 缩容期间副本减少，再挂一台可能丢数据 |
| `osd --all-available-devices` 当自动扩容 | 仅当 conf `OSD_ALLOW_ALL=1` 且插入的是**空盘**；插错系统盘会清空系统 |

半自动加盘（谨慎）：conf 设 `OSD_ALLOW_ALL=1` 后：

```bash
sudo bash install-ceph.sh osd --all-available-devices
```

---

### 7. 接到业务 Kubernetes（RBD CSI）

在 **Ceph bootstrap 节点**：

改 `ceph-nodes.conf` 节点后先刷新模板（MON 地址从 conf 读取，不要手改 YAML 里的 IP）：

```bash
bash install-ceph.sh csi-example
```

导出带真实密钥的清单（同时会按 conf 重写 example 和 `csi/generated/secret.yaml`）：

```bash
sudo bash install-ceph.sh export-rbd
# 生成 csi/generated/secret.yaml（含 client.kubernetes 密钥；monitors 来自 conf）
```

在 **K8s 控制面**（Helm 安装 [ceph-csi](https://github.com/ceph/ceph-csi) 的 RBD 图表，命名空间 `ceph-csi`）后：

```bash
kubectl create namespace ceph-csi
kubectl apply -f csi/generated/secret.yaml
kubectl apply -f csi/storageclass-rbd.yaml
```

PVC 使用 `storageClassName: ceph-rbd`。业务 Worker 必须能访问 MON `6789` 和 OSD 网段。

Helm 的 `csiConfig` 须与 Secret 里 `clusterID: ceph` 一致；具体 values 随 ceph-csi 版本变化，以官方 chart 为准。

---

### 8. 常用检查

```bash
ceph -s
ceph orch host ls
ceph osd tree
ceph osd pool ls
ceph auth get client.kubernetes
```

`bash install-ceph.sh --help`  
`bash install-ceph.sh help osd`（任意命令：`help <命令>` 或 `<命令> --help`）

---

### 9. 和业务集群的关系

| 集群 | 机器 | 装什么 |
|------|------|--------|
| 本目录 Ceph | ceph1/2/3 | MON / MGR / OSD |
| `install-k8s` | m1/m2/m3 + worker | 只装 CSI 客户端，**不跑 OSD** |
