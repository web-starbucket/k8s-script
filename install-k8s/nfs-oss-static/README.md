# OSS → NFS → Kubernetes 静态资源

本方案在独立 NFS 服务器 `172.16.10.124` 上运行 rclone 定时拉取阿里云 OSS 到现有共享目录 `/data/nfs/shared/website/gray`，然后由多个 `gray` namespace 前端 Pod 通过只读 NFS PVC 共享读取。

```text
阿里云 OSS
   │ rclone copy（OSS 源凭据，只读）
   ▼
NFS 服务器 172.16.10.124:/data/nfs/shared/website/gray
   │ NFSv4.1，只读导出给 K8s 节点
   ▼
PV ReadOnlyMany → PVC gray/pvc-nfs-gray-website → 多个前端 Pod /www/static
```

它不再把资源同步进 RustFS，也不依赖 OSS CSI 或 JuiceFS。若之后要切回 RustFS，需另行部署同步目标和 PV/PVC。

## 0. 前置确认

- NFS 服务器 `172.16.10.124` 可从所有运行前端 Pod 的 Kubernetes Worker 访问 TCP 2049。
- NFS 主机和 K8s 客户端均使用 NFSv4.1（此示例）；如果服务端版本不同，调整 PV 的 `mountOptions`。
- 示例 OSS 源：Bucket `obsbot-static-resource-cn`，前缀 `website/obsbot-website/beta`，成都 Endpoint `oss-cn-chengdu.aliyuncs.com`。
- RAM AccessKey 仅需 OSS 源前缀的读取/列举权限；不要使用主账号密钥。

## 1. 在 NFS 服务器准备目录和导出

你的 NFS 服务器 `172.16.10.124` 已有导出：`/data/nfs/shared 172.16.10.0/24(rw,sync,no_subtree_check)`。**保留现有 export，不要再为同一路径添加互相冲突的 ro export**。客户端访问范围建议限制为实际 Kubernetes 节点网段/节点 IP，并由 PV 和前端 Pod 以只读方式挂载。

在 Ubuntu NFS 服务器上安装工具并创建专用同步用户及资源目录：

```bash
sudo apt-get update
sudo apt-get install -y nfs-kernel-server rclone
sudo useradd --system --home /var/lib/oss-sync --create-home --shell /usr/sbin/nologin oss-sync || true
sudo install -d -o oss-sync -g oss-sync -m 0755 /data/nfs/shared/website/gray
sudo install -d -o root -g root -m 0755 /etc/rclone
sudo exportfs -rav
sudo exportfs -v
sudo systemctl enable --now nfs-kernel-server
sudo ss -lntp | grep ':2049'
```

同步服务在 NFS 服务器本机写入 `/data/nfs/shared/website/gray`；Kubernetes PV 设置 `nfs.readOnly: true`，前端 `volumeMounts` 也设置 `readOnly: true`。

## 2. 配置 OSS 源凭据和同步脚本

你已将同步脚本放在 `/opt/service/aliyun/oss/`。建议把 AccessKey 配置放在独立文件 `/etc/rclone/oss.conf`，不要写入脚本或提交 Git：

```bash
sudo install -d -o root -g root -m 0755 /etc/rclone
sudoedit /etc/rclone/oss.conf
```

文件内容（填入 OSS 只读 RAM 用户密钥）：

```ini
[oss]
type = s3
provider = Alibaba
env_auth = false
access_key_id = <OSS只读AccessKey>
secret_access_key = <OSS只读SecretKey>
endpoint = oss-cn-chengdu.aliyuncs.com
region = cn-chengdu
```

保存后设权限并确认同步脚本可执行：

```bash
sudo chown oss-sync:oss-sync /etc/rclone/oss.conf
sudo chmod 0600 /etc/rclone/oss.conf
sudo chmod 0755 /opt/service/aliyun/oss/oss-to-nfs-sync.sh
```

脚本默认每轮同步完成后等待 60 秒。检查 `OSS_SOURCE` 和 `NFS_DEST`，再安装并启用 systemd 服务：

```bash
# service 文件中的 ExecStart 已指向 /opt/service/aliyun/oss/oss-to-nfs-sync.sh
sudo install -o root -g root -m 0644 oss-to-nfs-sync.service /etc/systemd/system/oss-to-nfs-sync.service
sudo systemctl daemon-reload
sudo systemctl enable --now oss-to-nfs-sync.service
sudo systemctl status oss-to-nfs-sync.service
sudo journalctl -u oss-to-nfs-sync.service -f
```

间隔调整可编辑 systemd unit 的 `SYNC_INTERVAL_SECONDS`，再执行：

```bash
sudo systemctl daemon-reload
sudo systemctl restart oss-to-nfs-sync.service
```

该脚本使用 `rclone copy`：新增或变更对象会复制到 NFS；OSS 删除的对象**不会**自动从 NFS 删除。若需要严格镜像并删除目标端多余文件，要先在测试目录验证 `rclone sync`，确认不会误删后再改。

## 3. 验证 NFS 导出与内容

在 NFS 服务器：

```bash
sudo -u oss-sync rclone lsf oss:obsbot-static-resource-cn/website/obsbot-website/beta --config=/etc/rclone/oss.conf
find /data/nfs/shared/website/gray -maxdepth 2 -type f | head
```

在 `k8s-n3` 等每个 Kubernetes Worker：

```bash
showmount -e 172.16.10.124
nc -vz 172.16.10.124 2049
```

如果缺少 `showmount`/`nc`，安装 `nfs-common`/`netcat-openbsd`；NFSv4.1 主要需要放通 TCP 2049。

## 4. 准备 Kubernetes 节点并创建 PV/PVC

所有可能调度前端 Pod 的 Ubuntu Worker 都需要 NFS 客户端工具，并能连接 NFS 服务器 TCP 2049：

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
nc -vz 172.16.10.124 2049
```

本目录 `nfs-pv-pvc.yaml` 创建集群级 PV `pv-nfs-gray-website` 和 `gray/pvc-nfs-gray-website`。PV 标为 `ReadOnlyMany` 并设置 NFS `readOnly: true`；容量 `100Gi` 只是 Kubernetes 绑定声明，实际空间和配额由 NFS 文件系统控制。

```bash
kubectl apply -f nfs-pv-pvc.yaml
kubectl get pv pv-nfs-gray-website
kubectl -n gray get pvc pvc-nfs-gray-website
```

PVC 应为 `Bound`。若是 Pending，检查 PV/PVC accessModes、名称、绑定名及 NFS 服务器连通性：

```bash
kubectl -n gray describe pvc pvc-nfs-gray-website
kubectl describe pv pv-nfs-gray-website
```

## 5. 前端多个 Pod 挂载

将以下配置合并到前端 Deployment（修改容器名和挂载路径）：

```yaml
spec:
  template:
    spec:
      containers:
        - name: <前端容器名>
          volumeMounts:
            - name: website
              mountPath: /www/static
              readOnly: true
      volumes:
        - name: website
          persistentVolumeClaim:
            claimName: pvc-nfs-gray-website
```

多个 `gray` namespace Pod 可同时只读挂载同一个 RWX/ROX NFS PVC。验证：

```bash
kubectl -n gray exec <前端Pod名> -- ls -la /www/static
kubectl -n gray exec <前端Pod名> -- cat /www/static/sw.js
```

## 6. 缓存与更新行为

NFS 共享目录更新对客户端可见可能有短暂属性缓存；网页浏览器、Nginx 和 Service Worker 也可能缓存旧文件。建议静态 JS/CSS 使用带版本号的文件名，`sw.js` 配置为不缓存或短缓存。可通过 HTTP 响应头确认前端实际返回的是新文件。

## 7. 回滚

1. 将前端 Deployment 从 `pvc-nfs-gray-website` 切回旧挂载。
2. 确认没有 Pod 使用 PVC 后，再删除 PVC/PV（PV 为 Retain，不会删除 NFS 文件）。
3. 如不再同步，停止服务：`sudo systemctl disable --now oss-to-nfs-sync.service`。
