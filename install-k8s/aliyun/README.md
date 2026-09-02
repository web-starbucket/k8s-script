## 阿里云 OSS CSI（kubeadm 裸机）

在自建 Kubernetes 上安装 `ossplugin.csi.alibabacloud.com`，把 OSS Bucket 以 **静态 PV** 挂进 Pod。OSS 是对象存储，适合静态资源、备份、只读配置；**不要**当 MySQL/Redis 数据盘。

官方驱动：[kubernetes-sigs/alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)

ACK 控制台里的 CSI 组件**不能**装到 kubeadm 集群。本目录按 **非 ECS、只开 OSS** 来写。

---

### 0. 前提

- Kubernetes ≥ 1.26（本仓库集群为 1.33）
- 已装 Helm 3
- 节点能访问 OSS（机房一般用**公网 Endpoint**，例如成都 `oss-cn-chengdu.aliyuncs.com`）
- 节点内核支持 FUSE（Ubuntu 通常已有）
- RAM 子账号：只授该 Bucket 的 OSS 权限，不要用主账号 / 超级管理员

只读策略示例（把 `YOUR-BUCKET` 换成真实名）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["oss:Get*", "oss:List*"],
      "Resource": [
        "acs:oss:*:*:YOUR-BUCKET",
        "acs:oss:*:*:YOUR-BUCKET/*"
      ]
    }
  ]
}
```

Pod 需要写文件时，把 `Action` 改成 `oss:*`（仍限制在这一个 Bucket）。

---

### 1. 确认尚未安装

```bash
kubectl get csidriver
kubectl -n kube-system get pods | grep -E 'csi-plugin|csi-provisioner'
```

仅有 `csi.tigera.io`（Calico）是正常的。装好 OSS CSI 后应多出 `ossplugin.csi.alibabacloud.com`。

---

### 2. Helm 安装 OSS CSI（逐步）

Chart：`alibaba-cloud-csi-driver/alibaba-cloud-csi-driver`  
Release 名：`alibaba-cloud-csi-driver`  
命名空间：**`kube-system`**（CSI 控制器和节点插件都装在这里，不是某块本地磁盘分区）

`oss-csi-values.yaml` 已按裸机写好：**只开 OSS**，关闭云盘/NAS。把里面的 `deploy.regionID` 改成 Bucket 地域（成都 `cn-chengdu`，杭州 `cn-hangzhou`）。

#### 2.1 确认 Helm

```bash
helm version
# 应有 v3.x
```

#### 2.2 添加并更新仓库

```bash
helm repo add alibaba-cloud-csi-driver https://kubernetes-sigs.github.io/alibaba-cloud-csi-driver
helm repo update
helm search repo alibaba-cloud-csi-driver
```

`helm repo update` 成功时会看到 `Successfully got an update from the "alibaba-cloud-csi-driver" chart repository`。

#### 2.3 创建 OpenAPI 用的 Secret

CSI 组件调阿里云 OpenAPI 需要 `kube-system/csi-access-key`。可与第 3 步挂载用的 AK 为**同一 RAM 子账号**（仅 OSS 权限即可）。

```bash
kubectl -n kube-system create secret generic csi-access-key \
  --from-literal=id='LTAI...' \
  --from-literal=secret='...'
```

已存在则跳过，或先 `kubectl -n kube-system delete secret csi-access-key` 再创建。

#### 2.4 安装（没有就装，有就升级）

在仓库本目录执行（或把 `-f` 写成绝对路径）：

```bash
cd /opt/k8s-script/install-k8s/aliyun

helm upgrade --install alibaba-cloud-csi-driver \
  alibaba-cloud-csi-driver/alibaba-cloud-csi-driver \
  -n kube-system \
  -f oss-csi-values.yaml
```

成功示例：

```text
Release "alibaba-cloud-csi-driver" does not exist. Installing it now.
NAME: alibaba-cloud-csi-driver
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

`spec.template.spec.affinity... node-role.kubernetes.io/master` 的 **Warning 可忽略**（K8s 1.33 控制面标签已改为 `control-plane`）。

查看 Release：

```bash
helm -n kube-system list
helm -n kube-system status alibaba-cloud-csi-driver
```

#### 2.5 确认组件已启动

```bash
kubectl get csidriver
# 应有: ossplugin.csi.alibabacloud.com
# （csi.tigera.io 是 Calico，可同时存在）

kubectl -n kube-system get pods -o wide | grep -iE 'csi-plugin|csi-provisioner'
# csi-plugin 为 DaemonSet，每个节点一个 Running
# csi-provisioner 为 Deployment，Running

kubectl -n kube-system get ds,deploy | grep -iE 'csi|oss'
```

Pod 不是 Running 时：

```bash
kubectl -n kube-system describe pod -l app=csi-plugin
kubectl -n kube-system logs -l app=csi-plugin --tail=80
```

常见失败：镜像拉不到、`csi-access-key` 未创建、`regionID` 与镜像仓库地域不匹配。

#### 2.6 升级 / 卸载

改过 `oss-csi-values.yaml` 后同样执行 2.4 的 `helm upgrade --install ...`。

卸载 CSI（会中断已用 OSS 卷的 Pod，慎用）：

```bash
helm -n kube-system uninstall alibaba-cloud-csi-driver
```

数据仍在 OSS Bucket 里，卸载 CSI 不会删 Bucket。

组件在 **`kube-system`**；数据在 OSS；应用看到的是 Pod 的 `mountPath`。

---

### 3. 挂载用 Secret（与业务 Pod 同命名空间）

键名必须是 **`akId` / `akSecret`**：

```bash
kubectl -n default create secret generic oss-secret \
  --from-literal=akId='LTAI...' \
  --from-literal=akSecret='...'
```

---

### 4. 静态 PV / PVC

编辑 `examples/oss-pv-pvc.yaml`：

| 字段 | 含义 |
|------|------|
| `bucket` | Bucket 名 |
| `url` | Endpoint，**不要**带 `https://`。公网如 `oss-cn-chengdu.aliyuncs.com` |
| `path` | Bucket 内前缀，建议控制台先建好，如 `/k8s` |
| `fuseType` | 静态站 / 小文件随机读写： **`ossfs`（1.0）**。顺序读大文件才用 `ossfs2` |
| `storage` | 仅用于 PV/PVC 绑定，**不限制** Bucket 容量 |

```bash
kubectl apply -f examples/oss-pv-pvc.yaml
kubectl get pv pv-oss pvc pvc-oss -n default
```

期望 PVC **Bound**。

---

### 5. 挂到工作负载

```yaml
volumeMounts:
  - name: oss-static
    mountPath: /www/static          # 按应用实际目录改
volumes:
  - name: oss-static
    persistentVolumeClaim:
      claimName: pvc-oss
```

挂载后在 Pod 内核对路径是否与网页 URL 一致，避免多一层 `static`：

```text
网页请求:  /static/js/global-patch.js
若 Nginx root=/www，文件应在:  /www/static/js/global-patch.js
不要出现: /www/static/static/js/...
```

Gateway 要把 `/static` 转到挂了 OSS 的 Service，否则浏览器 404 是路由问题，不是 OSS 没挂上。

---

### 6. 自检

```bash
kubectl describe pvc pvc-oss -n default
kubectl describe pod <应用Pod> | grep -A20 Mounts
kubectl exec -it <应用Pod> -- ls -la /www/static
```

失败常见原因：AK 无权限、Endpoint 写错、节点出不了网、Bucket 前缀不存在、CSI Pod 未 Running、镜像拉不到。

---

### 不要做的事

- 不要用已废弃的 `flexVolume: alicloud/oss`
- 不要给 CSI 开 `csi.disk`（裸机没有 ECS 云盘）
- 没用阿里云 NAS 时保持 `csi.nas.enabled: false`
- 不要把 AccessKey 提交进 Git
