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
| `csi/secret.yaml.example` | CSI Secret 模板 |
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

### 6. 接到业务 Kubernetes（RBD CSI）

在 **Ceph bootstrap 节点**：

```bash
sudo bash install-ceph.sh export-rbd
# 生成 csi/generated/secret.yaml（含 client.kubernetes 密钥）
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

### 7. 常用检查

```bash
ceph -s
ceph orch host ls
ceph osd tree
ceph osd pool ls
ceph auth get client.kubernetes
```

`bash install-ceph.sh --help`

---

### 8. 和业务集群的关系

| 集群 | 机器 | 装什么 |
|------|------|--------|
| 本目录 Ceph | ceph1/2/3 | MON / MGR / OSD |
| `install-k8s` | m1/m2/m3 + worker | 只装 CSI 客户端，**不跑 OSD** |
