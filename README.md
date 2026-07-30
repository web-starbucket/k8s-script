

# K8s 1.33 脚本化搭建指南（kubeadm + VIP）

Ubuntu 24 · `install-k8s-1.33.sh` · 对外 API：`https://<VIP>:8443`


| 组件         | 作用                                                             |
| ---------- | -------------------------------------------------------------- |
| Keepalived | Master 间漂移 VIP                                                 |
| HAProxy    | `VIP:8443` → 各 Master `:6443`（本机 apiserver 占 6443，故 LB 用 8443） |
| CNI        | init 后须装网络插件，节点才 Ready                                         |


---

## 安装顺序

```text
conf → 全员 prepare → ssh-keys → vip-all → m1 init → cni-calico → join-all → status
```

```bash
# 每台物理机
chmod +x install-k8s-1.33.sh && sudo bash install-k8s-1.33.sh prepare

# 管理机（通常 m1）
sudo bash install-k8s-1.33.sh ssh-keys
sudo bash install-k8s-1.33.sh vip-all

# 仅 m1
sudo bash install-k8s-1.33.sh init \
  --apiserver-advertise-address=172.16.10.114 \
  --control-plane-endpoint=172.16.10.100:8443
sudo bash install-k8s-1.33.sh cni-calico
sudo bash install-k8s-1.33.sh join-all --prepare
sudo bash install-k8s-1.33.sh status
```

`bash install-k8s-1.33.sh --help`

---



## 1. 节点表 `k8s-nodes.conf`

格式：`IP|主机名|角色|用户|密码`（角色：`vip` / `master` / `worker`）

```text
172.16.10.100|k8s-vip|vip||
172.16.10.114|k8s-m1|master|root|你的密码
172.16.10.115|k8s-m2|master|root|你的密码
172.16.10.116|k8s-m3|master|root|你的密码
172.16.10.117|k8s-n1|worker|root|你的密码
```

```bash
chmod 600 k8s-nodes.conf
bash install-k8s-1.33.sh nodes          # 核对 VIP / Master，须与真实网卡 IP 一致
```

增删节点：改 conf → `hosts-all` →（master 用 `join-masters --prepare`，worker 用 `join-workers --prepare`）

---



## 2. prepare / hosts / ssh-keys


| 命令                    | 说明                                 |
| --------------------- | ---------------------------------- |
| `prepare`             | 每台执行：swap、containerd、kubeadm、hosts |
| `hosts` / `hosts-all` | 刷新 hosts；管理机一键用 `hosts-all`        |
| `ssh-keys`            | 管理机按 conf 分发密钥（需真实密码）              |


```bash
sudo bash install-k8s-1.33.sh prepare
sudo bash install-k8s-1.33.sh ssh-keys
sudo bash install-k8s-1.33.sh hosts-all   # 改 conf 后
```

---



## 3. VIP（init 之前）

Worker 不装。管理机：

```bash
sudo bash install-k8s-1.33.sh vip-all
# sudo bash install-k8s-1.33.sh vip-all --iface=ens18
```

```bash
ping -c2 172.16.10.100
ss -lntp | grep 8443
```

init 前 `healthz` 失败正常。

---



## 4. Master-1：init

只执行一次：

```bash
sudo bash install-k8s-1.33.sh init \
  --apiserver-advertise-address=172.16.10.114 \
  --control-plane-endpoint=172.16.10.100:8443

curl -k https://172.16.10.100:8443/healthz   # ok
kubectl get nodes -o wide                    # 多为 NotReady，待 CNI
```

---



## 5. CNI（默认 Calico）

join 其它节点前在 m1 安装：

```bash
sudo bash install-k8s-1.33.sh cni-calico
kubectl get pods -n calico-system -o wide
kubectl get nodes                            # m1 应变 Ready
```


| 镜像        | 默认地址                                           |
| --------- | ---------------------------------------------- |
| 控制面       | `registry.aliyuncs.com/google_containers`（阿里云） |
| operator  | `quay.m.daocloud.io/tigera/operator`           |
| calico 组件 | `docker.m.daocloud.io/calico/...`              |


> 阿里云公共仓无完整 Calico；自有 ACR 可 `export CALICO_REGISTRY=... QUAY_MIRROR=...` 后 `sudo -E bash ... cni-calico`。


| 现象               | 处理                                |
| ---------------- | --------------------------------- |
| NotReady         | 未装 CNI / Pod 未就绪                  |
| ImagePullBackOff | 查 `GH_PROXY`、镜像地址；重跑 `cni-calico` |
| CRD 注解超限         | 脚本已用 server-side apply            |


---



## 6. 加入其余节点

在已 init + CNI 的 m1：

```bash
sudo bash install-k8s-1.33.sh join-all --prepare
# sudo bash install-k8s-1.33.sh join-masters --prepare
# sudo bash install-k8s-1.33.sh join-workers --reset --only=172.16.10.117
sudo bash install-k8s-1.33.sh status
```

有旧残留时加 `--reset`。已在集群的节点会跳过。

---



## 7. 扩容 / 清理


| 操作       | 命令                                 |
| -------- | ---------------------------------- |
| 加 Master | conf 加行 → `join-masters --prepare` |
| 加 Worker | conf 加行 → `join-workers --prepare` |
| 清集群      | `reset-all --yes`                  |
| 清单机      | `reset --yes --vip`                |


```bash
sudo bash install-k8s-1.33.sh reset-all --dry-run
sudo bash install-k8s-1.33.sh reset-all --yes
```

---



## 8. 命令与参数



### 8.1 命令含义


| 命令             | 在哪执行           | 含义                                               |
| -------------- | -------------- | ------------------------------------------------ |
| `nodes`        | 任意             | 打印当前 conf 节点表（隐藏密码），核对 VIP / Master / SSH 目标     |
| `prepare`      | 每台物理机          | 关 swap、装 containerd/kubeadm/kubectl、写 hosts、预拉镜像 |
| `hosts`        | 单机             | 仅按 conf 更新 `/etc/hosts`，并按本机 IP 设置主机名            |
| `hosts-all`    | 管理机            | 远程给 conf 中全部 master/worker 执行 `hosts`            |
| `ssh-keys`     | 管理机            | 按 conf 账号密码分发 SSH 公钥，并尽量做到节点互通免密                 |
| `vip`          | 单台 Master      | 本机安装并配置 HAProxy + Keepalived                     |
| `vip-all`      | 管理机            | 远程给全部 Master 装 VIP；priority 自动 100、90、80…        |
| `init`         | **仅 Master-1** | `kubeadm init`，创建控制面（须带 VIP:8443）                |
| `cni-calico`   | Master-1       | 安装 Calico 网络插件（国内镜像）；init 后、join 前执行             |
| `cni-flannel`  | Master-1       | 安装 Flannel（可选；勿与 Calico 同装）                      |
| `join`         | 目标节点           | 手动 `kubeadm join`（需自己提供 token 等）                 |
| `join-masters` | Master-1       | 自动生成证书/token，远程把尚未入群的 Master 加成控制面               |
| `join-workers` | Master-1       | 自动生成 token，远程把尚未入群的 Worker 加入集群                  |
| `join-all`     | Master-1       | 先 `join-masters`，再 `join-workers`                |
| `status`       | 控制面            | 查看 nodes / pods                                  |
| `reset`        | 本机             | 清理本机 Kubernetes（kubeadm reset + CNI/kubelet 残留）  |
| `reset-all`    | 管理机            | 按 conf 一键清理全部 master/worker                      |




### 8.2 参数含义


| 命令             | 参数                                     | 含义                                                         |
| -------------- | -------------------------------------- | ---------------------------------------------------------- |
| `ssh-keys`     | `--no-mutual`                          | 只把管理机公钥拷到各节点，不做节点之间公钥互换                                    |
| `hosts-all`    | `--only=<IP>`                          | 只刷新指定 IP 那一台                                               |
|                | `--dry-run`                            | 只打印将操作的节点，不真正执行                                            |
| `vip`          | `--vip=<IP>`                           | 浮动 VIP；省略则读 conf 里 `vip` 行                                 |
|                | `--peers=<IP,IP>`                      | HAProxy 后端 Master 列表；省略则读 conf 全部 `master`                 |
|                | `--iface=<网卡>`                         | Keepalived 绑定的网卡（如 ens18）；省略则自动检测                          |
|                | `--priority=<N>`                       | 抢 VIP 优先级，数字越大越优先（如 100 / 90 / 80）                         |
|                | `--lb-port=8443`                       | HAProxy 对外端口（默认 8443，避免和本机 6443 冲突）                        |
| `vip-all`      | `--iface=<网卡>`                         | 各 Master 网卡名相同时可统一指定；不一致则不要传                               |
|                | `--lb-port=8443`                       | 同 `vip`                                                    |
|                | `--dry-run`                            | 只预览各机将执行的 vip 命令                                           |
| `init`         | `--apiserver-advertise-address=<本机IP>` | **必填**，本机真实网卡 IP                                           |
|                | `--control-plane-endpoint=<VIP:8443>`  | 集群 API 入口；后续 join / kubectl 都连这里                           |
|                | `--pod-network-cidr=10.244.0.0/16`     | Pod 网段，须与 CNI 一致                                           |
| `join`         | `<VIP>:8443`                           | 加入地址（第一个位置参数）                                              |
|                | `--token`                              | 引导 token                                                   |
|                | `--discovery-token-ca-cert-hash`       | 校验控制面 CA                                                   |
|                | `--control-plane`                      | 以控制面身份加入（Master）                                           |
|                | `--certificate-key`                    | 控制面证书密钥（upload-certs 生成）                                   |
|                | `--apiserver-advertise-address=<本机IP>` | 该 Master 对外宣告的本机 IP                                        |
| `join-masters` | `--prepare`                            | join 前先在目标机跑一遍 `prepare`                                   |
|                | `--reset`                              | join 前先清目标机旧集群残留                                           |
|                | `--no-vip`                             | 不加节点前不跑 `vip-all`（默认会先刷新 VIP）                              |
|                | `--iface=<网卡>`                         | 传给内部 `vip-all`                                             |
|                | `--only=<IP>`                          | 只处理 conf 中该 IP                                             |
|                | `--dry-run`                            | 只预览，不执行                                                    |
| `join-workers` | `--prepare`                            | join 前远程 `prepare`                                         |
|                | `--reset`                              | 或检测到残留时先 `reset` 再 join                                    |
|                | `--only=<IP>`                          | 只加指定 Worker                                                |
|                | `--dry-run`                            | 只预览                                                        |
| `join-all`     | `--prepare` 等                          | 传给 masters/workers；另可用 `--masters-only` / `--workers-only` |
| `reset`        | `--vip`                                | 同时停掉并清理 HAProxy / Keepalived                               |
|                | `--yes` / `-y`                         | 跳过确认等待                                                     |
| `reset-all`    | `--yes` / `-y`                         | 跳过危险确认（建议加上）                                               |
|                | `--keep-vip`                           | 只清 K8s，保留 VIP 组件                                           |
|                | `--only=<IP>`                          | 只清理一台                                                      |
|                | `--dry-run`                            | 只列出将清理的节点                                                  |




### 8.3 环境变量含义


| 变量                  | 默认                    | 含义                            |
| ------------------- | --------------------- | ----------------------------- |
| `K8S_NODES_FILE`    | 同目录 `k8s-nodes.conf`  | 节点表文件路径                       |
| `K8S_NODES`         | 空                     | 若设置则直接用该文本作节点表（不再读文件）         |
| `SET_HOSTNAME`      | `1`                   | `0` 时 `hosts`/`prepare` 不改主机名 |
| `LB_PORT`           | `8443`                | API 负载端口                      |
| `POD_CIDR`          | `10.244.0.0/16`       | Pod 网段（init / Calico）         |
| `SERVICE_CIDR`      | `10.96.0.0/12`        | Service 网段                    |
| `IMAGE_REPOSITORY`  | 阿里云 google_containers | kubeadm 控制面镜像仓库               |
| `PAUSE_IMAGE`       | 阿里云 pause:3.10        | containerd sandbox 镜像         |
| `DOCKER_MIRROR`     | DaoCloud              | docker.io 拉取加速                |
| `GH_PROXY`          | ghfast.top            | 拉 GitHub yaml；设空则直连           |
| `CALICO_REGISTRY`   | docker.m.daocloud.io  | Calico 组件镜像仓库                 |
| `CALICO_IMAGE_PATH` | `calico`              | 组件镜像路径前缀                      |
| `QUAY_MIRROR`       | quay.m.daocloud.io    | tigera-operator 镜像前缀          |
| `CALICO_VERSION`    | `v3.29.3`             | Calico 清单版本                   |
| `KUBE_VERSION`      | 空=最新 1.33.x           | 如 `1.33.2-1.1` 锁定 apt 版本      |
| `VIP_IFACE`         | 空=自动检测                | Keepalived 默认网卡               |
| `VIP_ROUTER_ID`     | `51`                  | VRRP 路由 ID（同集群须一致）            |
| `VIP_AUTH_PASS`     | 脚本内默认                 | Keepalived 认证口令               |


```bash
export GH_PROXY=
export CALICO_REGISTRY=docker.m.daocloud.io
sudo -E bash install-k8s-1.33.sh cni-calico
```

---



## 9. Kuboard

`admin.conf` 的 `server:` 须为 `https://VIP:8443`。旁路可参考 `kuboard/docker-compose.yml`。

---



## 10. 排查


| 现象          | 处理                                                |
| ----------- | ------------------------------------------------- |
| ping 不通 VIP | keepalived、网卡、同网段空闲 IP、`virtual_router_id`        |
| 8443 不通     | `systemctl status haproxy`；`ss -lntp | grep 8443` |
| join 失败     | 用 VIP:8443；目标机先 `reset` 清残留                       |
| conf 不生效    | 改服务器上脚本同目录 conf；`nodes` 核对                        |
| SSH 只处理一台   | 更新脚本（while-read 内 ssh 须 `-n`）                     |


```bash
journalctl -u keepalived -u haproxy -n 50 --no-pager
kubectl get pods -A -o wide
kubectl describe node <名>
```

---



## 检查清单

- [ ] conf 与真实 IP / 主机名一致，`nodes` 正确  
- [ ] 全员 `prepare`，管理机 `ssh-keys`、`vip-all`  
- [ ] 仅 m1 `init`（endpoint=`VIP:8443`）+ `cni-calico`  
- [ ] `join-all` 后节点 Ready；`curl -k https://VIP:8443/healthz` → `ok`
