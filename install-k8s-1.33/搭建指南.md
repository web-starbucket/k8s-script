# Kubernetes 1.33 实验集群（Master + VIP + HAProxy/Keepalived + Worker）

使用 `install-k8s-1.33.sh` 在 Ubuntu 24.04 上搭建 **kubeadm + containerd** 的 **1.33**。

推荐顺序：**先脚本初始化一台 Master → 安装网络插件（CNI）→ 再脚本加入其余 Master / Worker**。

---


| 组件             | 作用                                                                     |
| -------------- | ---------------------------------------------------------------------- |
| **Keepalived** | 在 Master 间漂移 **VIP**；HAProxy 挂了会降权，VIP 漂到另一台                           |
| **HAProxy**    | 把 `VIP:8443` **四层转发**到各 `MasterIP:6443`，做 API 负载与健康检查                  |
| **为何用 8443**   | 本机 `kube-apiserver` 已占用 `*:6443`，HAProxy 不能再绑 `*:6443`，故 LB 用 **8443** |
| **CNI**        | 装完 `init` 后节点多为 `NotReady`，**必须装网络插件**后才 Ready                         |


对外 API：`https://<VIP>:8443`

---



## 推荐安装总览

### 步骤顺序

```text
1. 填 k8s-nodes.conf
2. 全部物理节点 prepare（含 hosts）
3. 管理机 ssh-keys（免密）
4. 管理机 vip-all（所有 Master 装 HAProxy + Keepalived）
5. 仅 Master-1：init（endpoint = VIP:8443）
6. 仅 Master-1：安装 CNI（默认 Calico：cni-calico）← 再 join 其它节点
7. Master-1：join-masters / join-workers / join-all（自动 token，无需手抄）
8. status 检查；导入 Kuboard
```

### 脚本命令总结（按顺序）

```bash
# —— 每台 master/worker ——
chmod +x install-k8s-1.33.sh
sudo bash install-k8s-1.33.sh prepare

# —— 管理机（通常 Master-1）——
sudo bash install-k8s-1.33.sh ssh-keys
sudo bash install-k8s-1.33.sh vip-all
# sudo bash install-k8s-1.33.sh vip-all --iface=ens33

# —— 仅 Master-1 ——
sudo bash install-k8s-1.33.sh init \
  --apiserver-advertise-address=172.16.10.115 \
  --control-plane-endpoint=172.16.10.114:8443

sudo bash install-k8s-1.33.sh cni-calico

sudo bash install-k8s-1.33.sh join-all --prepare
# 或分步：
# sudo bash install-k8s-1.33.sh join-masters --prepare
# sudo bash install-k8s-1.33.sh join-workers --prepare

sudo bash install-k8s-1.33.sh status
```

查看帮助：`bash install-k8s-1.33.sh --help`

### 命令一览

| 命令 | 在哪执行 | 作用 |
|------|----------|------|
| `nodes` | 任意 | 打印节点表（隐藏密码） |
| `prepare` | 每台物理节点 | 关 swap、装 containerd / kubeadm 等，并写 hosts |
| `hosts` | 需要刷新时 | 仅按 conf 写 `/etc/hosts`、可选改主机名 |
| `ssh-keys` | 管理机 | 按 conf 密码分发 SSH 公钥并互通 |
| `vip` | 单台 Master | 本机装 HAProxy + Keepalived |
| `vip-all` | 管理机 | 远程一键给全部 Master 装 VIP |
| `init` | **仅 Master-1** | `kubeadm init`（带 VIP:8443） |
| `cni-calico` | Master-1 | 安装 Calico（默认 CNI） |
| `cni-flannel` | Master-1 | 安装 Flannel（可选，勿与 Calico 同装） |
| `join` | 目标节点 | 手动 join（需自备 token 等） |
| `join-masters` | Master-1 | 自动加尚未入群的 Master |
| `join-workers` | Master-1 | 自动加尚未入群的 Worker |
| `join-all` | Master-1 | 先 masters 再 workers |
| `status` | 控制面 | `kubectl get nodes/pods` |
| `reset` | 本机 | `kubeadm reset` 清本机集群状态 |

### 常用参数说明

| 命令 | 参数 | 说明 |
|------|------|------|
| `ssh-keys` | `--no-mutual` | 只把管理机公钥拷出去，不做节点间公钥互换 |
| `vip` | `--vip=<IP>` | VIP 地址；省略则读 conf 中 `vip` 行 |
| | `--peers=<IP,IP>` | 后端 Master 列表；省略则读 conf 全部 `master` |
| | `--iface=<网卡>` | 绑定网卡；省略则自动检测默认路由网卡 |
| | `--priority=<N>` | Keepalived 优先级，越大越优先抢 VIP（如 100 / 90 / 80） |
| | `--lb-port=8443` | HAProxy 对外端口（默认 8443） |
| `vip-all` | `--iface=<网卡>` | 各 Master 网卡名相同时可指定；不同则不要传 |
| | `--lb-port=8443` | 同 `vip` |
| | `--dry-run` | 只打印将在各 Master 上执行的命令，不实际部署 |
| `init` | `--apiserver-advertise-address=<本机IP>` | **必填**，本机真实 IP |
| | `--control-plane-endpoint=<VIP:8443>` | 强烈建议填写，后续 join 都连这个地址 |
| | `--pod-network-cidr=10.244.0.0/16` | Pod 网段，需与 CNI 一致 |
| `join` | `<VIP>:8443` | 第一个位置参数，API 入口 |
| | `--token` / `--discovery-token-ca-cert-hash` | 发现与校验 |
| | `--control-plane` + `--certificate-key` | 加控制面时需要 |
| | `--apiserver-advertise-address=<本机IP>` | 控制面 join 时建议带上 |
| `join-masters` | `--prepare` | join 前先在目标机跑 `prepare` |
| | `--no-vip` | 不加节点前不跑 `vip-all`（默认会跑） |
| | `--iface=<网卡>` | 传给内部的 `vip-all` |
| | `--only=<IP>` | 只处理 conf 中该 IP |
| | `--dry-run` | 只预览，不执行 |
| `join-workers` | `--prepare` / `--only=<IP>` / `--dry-run` | 含义同上（无 vip 相关参数） |
| `join-all` | `--prepare` 等 | 传给 `join-masters` / `join-workers`；另支持 `--masters-only` / `--workers-only` |

### 常用环境变量

| 变量 | 默认（摘要） | 说明 |
|------|--------------|------|
| `K8S_NODES_FILE` | 同目录 `k8s-nodes.conf` | 节点表路径 |
| `K8S_NODES` | （空则读文件） | 直接内联节点表文本 |
| `SET_HOSTNAME` | `1` | `0` 则 `hosts`/`prepare` 不改主机名 |
| `LB_PORT` | `8443` | API LB 端口 |
| `POD_CIDR` | `10.244.0.0/16` | Pod 网段（init / Calico） |
| `SERVICE_CIDR` | `10.96.0.0/12` | Service 网段 |
| `IMAGE_REPOSITORY` | 阿里云 `google_containers` | 控制面镜像仓库 |
| `PAUSE_IMAGE` | 阿里云 `pause:3.10` | containerd sandbox |
| `DOCKER_MIRROR` | DaoCloud | Docker Hub 加速 |
| `GH_PROXY` | `https://ghfast.top/` | 拉 CNI yaml；设空则直连 GitHub |
| `KUBE_VERSION` | （空=仓库最新 1.33.x） | 如 `1.33.2-1.1` 锁定版本 |
| `VIP_IFACE` / `VIP_ROUTER_ID` / `VIP_AUTH_PASS` | 见脚本 | Keepalived 默认网卡 / 路由 ID / 认证 |

示例（覆盖默认后执行）：

```bash
export GH_PROXY=
export DOCKER_MIRROR=https://docker.1ms.run
sudo -E bash install-k8s-1.33.sh prepare
sudo -E bash install-k8s-1.33.sh cni-calico
```

---



## 1. 地址规划（可配置多台）

节点表：同目录 `k8s-nodes.conf`（也可用环境变量 `K8S_NODES`）。

格式：`IP|主机名|角色|用户名|密码`（`vip` / `master` / `worker`；vip 的用户密码可空）。

```text
172.16.10.114|k8s-vip|vip||
172.16.10.115|k8s-m1|master|root|你的密码
172.16.10.116|k8s-m2|master|root|你的密码
172.16.10.117|k8s-m3|master|root|你的密码
172.16.10.118|k8s-n1|worker|root|你的密码
172.16.10.119|k8s-n2|worker|root|你的密码
172.16.10.120|k8s-n3|worker|root|你的密码
```

```bash
chmod 600 k8s-nodes.conf          # 含密码，收紧权限
bash install-k8s-1.33.sh nodes    # 查看（不显示密码）
```

- **新增节点**：conf 加一行 → 全员 `hosts` / 新机 `prepare`→ `join-masters` 或 `join-workers`
- **删除节点**：`kubectl drain/delete` → 从表去掉 → 全员 `hosts` → 管理机重跑 `vip-all`

`prepare` / `hosts` 会按表写入 `/etc/hosts`，并按本机 IP 自动 `hostnamectl`（`SET_HOSTNAME=0` 可关）。

---



## 2. 所有节点：prepare（含 hosts）

在 **每一台** master / worker 上（或先拷脚本再执行）：

```bash
chmod +x install-k8s-1.33.sh
sudo bash install-k8s-1.33.sh prepare
```

仅刷新 hosts / 主机名：

```bash
sudo bash install-k8s-1.33.sh hosts
```



### 2.1 节点 SSH 免密

在 `k8s-nodes.conf` 填好各 **master/worker** 的 `用户名|密码` 后，在管理机（通常 m1）执行：

```bash
sudo bash install-k8s-1.33.sh ssh-keys
```

脚本用 **sshpass** 按 conf 非交互 `ssh-copy-id`，并互换公钥。vip 行不参与 SSH。

```bash
ssh root@172.16.10.116
ssh root@k8s-m2
```

---



## 3. VIP 搭建（HAProxy + Keepalived）— 全部 Master

**必须在** `kubeadm init` **之前完成**；Worker 不装 VIP。

在管理机（通常 m1，已 `ssh-keys`）执行：

```bash
ip -br a   # 可选：查网卡名

sudo bash install-k8s-1.33.sh vip-all

# 各 Master 网卡名相同时：
sudo bash install-k8s-1.33.sh vip-all --iface=ens33
```

脚本会：读 conf 全部 master → 同步脚本 → 远程 `vip`，priority 自动 100、90、80… → HAProxy `VIP:8443` → 各 Master `:6443`。

验证：

```bash
ping -c 2 172.16.10.114
ss -lntp | grep 8443
systemctl status haproxy keepalived --no-pager
```

此时 apiserver 尚未起来，`curl https://VIP:8443/healthz` 失败属正常；**init 后再测**。

单机 VIP（一般不必）：

```bash
sudo bash install-k8s-1.33.sh vip --iface=<网卡名> --priority=100
```

---



## 4. 仅 Master-1：脚本 init

**只在第一台 Master（如 172.16.10.115 / k8s-m1）执行一次**，不要在其它节点 init。

```bash
sudo bash install-k8s-1.33.sh init \
  --apiserver-advertise-address=172.16.10.115 \
  --control-plane-endpoint=172.16.10.114:8443
```

说明：

- `--apiserver-advertise-address`：本机真实 IP（m1）
- `--control-plane-endpoint`：**VIP:8443**（后面所有 join 都连这个地址）

验证：

```bash
curl -k https://172.16.10.114:8443/healthz
# 期望: ok

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes -o wide
# 此时多为 NotReady —— 正常，下一步装 CNI
```

---



## 5. 安装网络插件（CNI）

`kubeadm init` 之后 **必须安装 CNI**，否则节点一直 `NotReady`，Pod 也起不来。  
**建议在 join 其它节点之前**先在 Master-1 装好。本指南默认使用 **Calico**。

### 5.1 Calico（默认）

在 Master-1 执行。脚本经 `GH_PROXY` 安装 tigera-operator，并把 custom-resources 中的 Pod CIDR 改为 `POD_CIDR`（默认 `10.244.0.0/16`，与 `init` 一致）。

```bash
# 在 Master-1
sudo bash install-k8s-1.33.sh cni-calico
```

检查：

```bash
kubectl get pods -n tigera-operator -o wide
kubectl get pods -n calico-system -o wide
# 或
kubectl get pods -A | grep -iE 'calico|tigera'

kubectl get nodes -o wide
# Master-1 应变为 Ready（Calico 拉镜像可能稍慢，等几分钟）
```



### 5.2 常见现象


| 现象                            | 说明                                                      |
| ----------------------------- | ------------------------------------------------------- |
| init 后 `NotReady`             | 未装 CNI 或 CNI Pod 未 Ready                                |
| Calico Pod `ImagePullBackOff` | 国内镜像/代理问题，检查 `GH_PROXY`、`DOCKER_MIRROR`                 |
| 其它节点 join 后仍 `NotReady`       | 等 Calico DaemonSet 调度到新节点；`kubectl get pods -A -o wide` |


---



## 6. 脚本加入其余 Master / Worker

在 **已 init 且已装 CNI 的 Master-1**（有 `/etc/kubernetes/admin.conf`）上执行。  
脚本自动生成 token / `upload-certs`，SSH 到 conf 里尚未入群的节点并 join；**已在集群的跳过**，无需手抄命令。

```bash
# 只加其余 Master（默认先跑 vip-all）
sudo bash install-k8s-1.33.sh join-masters
# 新机还没 prepare：
sudo bash install-k8s-1.33.sh join-masters --prepare
# 只加某一台：
# sudo bash install-k8s-1.33.sh join-masters --only=172.16.10.116

# 只加 Worker
sudo bash install-k8s-1.33.sh join-workers
sudo bash install-k8s-1.33.sh join-workers --prepare

# Master + Worker 一起（推荐收尾一步做完）
sudo bash install-k8s-1.33.sh join-all --prepare

# 预览不执行
sudo bash install-k8s-1.33.sh join-masters --dry-run
sudo bash install-k8s-1.33.sh join-workers --dry-run
```

检查：

```bash
sudo bash install-k8s-1.33.sh status
# 或
kubectl get nodes -o wide
kubectl get pods -A
```

期望：各 Master 为 `control-plane`，Worker 为普通节点，状态多为 `Ready`。

### 6.1 仍可手动 join（可选）

在 Master-1：

```bash
sudo kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command
```

其它 Master（端口 **8443**）：

```bash
sudo bash install-k8s-1.33.sh join 172.16.10.114:8443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <CERTIFICATE_KEY> \
  --apiserver-advertise-address=<本机IP>
```

Worker：

```bash
sudo bash install-k8s-1.33.sh join 172.16.10.114:8443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

---



## 7. 后续扩容

### 加 Master

1. `k8s-nodes.conf` 增加一行
2. 管理机：`sudo bash install-k8s-1.33.sh join-masters --prepare`
  （含 `vip-all` + 自动 token/证书 + 远程 join）



### 加 Worker

1. conf 加 worker 行
2. `sudo bash install-k8s-1.33.sh join-workers --prepare`

---



## 8. 导入 Kuboard

`admin.conf` 里 `server:` 应为：

```text
https://172.16.10.114:8443
```

若仍是某台 Master 的 `6443`，请改成 `VIP:8443` 再导入。

同目录可参考 `kuboard/docker-compose.yml` 在旁路机器起 Kuboard。

---



## 9. 故障排查


| 现象                 | 处理                                                           |
| ------------------ | ------------------------------------------------------------ |
| ping 不通 VIP        | 查 keepalived、网卡名、防火墙、`virtual_router_id` 是否一致                |
| VIP 在，8443 不通      | `systemctl status haproxy`；`ss -lntp                         |
| haproxy 起不来        | `journalctl -u haproxy`；是否未开 `ip_nonlocal_bind`              |
| init 后 healthz 失败  | `curl -k https://127.0.0.1:6443/healthz`                     |
| 节点长期 NotReady      | 是否执行了 `cni-calico`；看 `calico-system` / `tigera-operator` Pod |
| join 连不上           | 确认用的是 **VIP:8443**，不是 6443                                   |
| Calico yaml / 镜像失败 | 调整 `GH_PROXY`、`DOCKER_MIRROR`；必要时配置 Calico 国内镜像              |


```bash
sudo journalctl -u keepalived -u haproxy -n 50 --no-pager
sudo cat /etc/haproxy/haproxy.cfg
sudo cat /etc/keepalived/keepalived.conf
kubectl get pods -A -o wide
kubectl describe node <节点名>
```

