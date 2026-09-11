## PostgreSQL：StatefulSet + Ceph RBD + 流复制 + 故障转移

- **一个** `StatefulSet/postgres`，`replicas: 2`（`postgres-0` / `postgres-1`）
- **一 Pod 一盘**（`ceph-rbd`，默认 20Gi）
- 默认库/用户：`obsbot` / `obsbot`（Secret `postgres-auth`）
- ConfigMap `postgres-topology`：`primary-pod` 记录当前主
- 客户端连 **Service `postgres`**（`postgres.role=primary`）← 可选 TCPRoute
- **`postgres-controller`**：当前主挂掉 ≥1s → `pg_promote()` 升备库；**不回切**

### 1. 部署

```bash
cd /opt/k8s-script/install-k8s/postgres+ceph
# 部署前改掉 Secret 默认密码
kubectl apply -f postgres.yaml
kubectl apply -f postgres-controller.yaml
# 可选对外 TCP
kubectl apply -f tcproute-postgres.yaml

kubectl get sts,pod,pvc,ep -l app=postgres
kubectl logs -f deploy/postgres-controller
```

日志示例：

```text
[08:24:08] 主 postgres-0 Ready  |  从 postgres-1 Ready 复制=正常 status=streaming 源=postgres-0.postgres-headless
```

### 2. 从旧版 hostPath 单实例迁移

旧 `install-k8s/postgres/obsbot-postgres.yaml` 使用节点 `hostPath`，与 `postgres+ceph` **不能共存**（同名 STS/Service）。

迁移数据（示例）：

```bash
# 1) 停旧实例
kubectl delete sts postgres --cascade=foreground

# 2) 部署新栈，等 postgres-0 Ready
kubectl apply -f postgres.yaml
kubectl apply -f postgres-controller.yaml

# 3) 从旧目录 dump / 恢复到新主（在能访问旧数据的节点执行）
# pg_dump -h ... -U obsbot obsbot | psql -h postgres -U obsbot obsbot
```

全新部署直接 apply 即可。

### 3. 连接

```bash
kubectl run psql-cli --rm -it --restart=Never \
  --image=registry.cn-global.starbucket.com.cn/starbucket/docker.io/library/postgres:16 \
  -- psql -h postgres -U obsbot -d obsbot
```

### 4. 测故障转移

```bash
kubectl logs -f deploy/postgres-controller
kubectl delete pod postgres-0 --grace-period=0 --force

kubectl get cm postgres-topology -o jsonpath='{.data.primary-pod}{"\n"}'
kubectl get ep postgres
```

`postgres-0` 恢复后会 `pg_rewind`/`pg_basebackup` 重新挂到新主。手工切回：`bash promote-replica.sh postgres-0`

### 5. 改密码

先在**当前主**改库内用户，再改 Secret，最后滚动重启：

```bash
PRI=$(kubectl get cm postgres-topology -o jsonpath='{.data.primary-pod}')
OLD=$(kubectl get secret postgres-auth -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

kubectl exec "$PRI" -c postgres -- psql -U obsbot -d obsbot -c \
  "ALTER USER obsbot WITH PASSWORD '新密码';
   ALTER USER replicator WITH PASSWORD '新复制密码';"

kubectl patch secret postgres-auth --type merge -p '{"stringData":{
  "POSTGRES_PASSWORD":"新密码",
  "replication-password":"新复制密码"
}}'
kubectl rollout restart deploy/postgres-controller
kubectl rollout restart sts/postgres
```

### 6. 注意

- 主库 initdb 启用 `--data-checksums`，便于 `pg_rewind`。
- 从库改指向靠 **删除 Pod**，entrypoint 会 `pg_basebackup`/`pg_rewind`（会短暂中断该副本）。
- 客户端应连 Service `postgres` 或 Gateway VIP，不要直连 Pod。
- 生产大规模 HA 建议 Patroni / CloudNativePG / Operator。
