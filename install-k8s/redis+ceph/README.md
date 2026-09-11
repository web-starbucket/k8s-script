## Redis：StatefulSet + Ceph RBD + 故障转移 + TCPRoute

- **一个** `StatefulSet/redis`，`replicas: 2`（`redis-0` / `redis-1`）
- **一 Pod 一盘**（`ceph-rbd`，AOF 持久化）
- ConfigMap `redis-topology`：`primary-pod` 记录当前主
- 客户端连 **Service `redis`**（`redis.role=primary`）← 可选 TCPRoute
- **`redis-controller`**：当前主挂掉 ≥1s → 升从；**不回切**

### 1. 部署

```bash
cd /opt/k8s-script/install-k8s/redis+ceph
kubectl apply -f redis.yaml
kubectl apply -f redis-controller.yaml
# 可选对外 TCP
kubectl apply -f tcproute-redis.yaml

kubectl get sts,pod,pvc,ep -l app=redis
kubectl logs -f deploy/redis-controller
```

日志示例：

```text
[08:24:08] 主 redis-0 Ready  |  从 redis-1 Ready 复制=正常 link=up sync=0 源=redis-0.redis-headless
```

### 2. 连接

集群内：

```bash
PW=$(kubectl get secret redis-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl run redis-cli --rm -it --restart=Never \
  --image=registry.cn-global.starbucket.com.cn/starbucket/docker.io/library/redis:8 \
  -- redis-cli -h redis -a "$PW" --no-auth-warning INFO replication
```

### 3. 测故障转移

```bash
kubectl logs -f deploy/redis-controller
kubectl delete pod redis-0 --grace-period=0 --force
# 约 1–3s：升主 redis-1，ep/redis 指向 redis-1

kubectl get cm redis-topology -o jsonpath='{.data.primary-pod}{"\n"}'
kubectl get ep redis
```

`redis-0` 恢复后会成为从库，**不会**自动切回。手工切回：`bash promote-replica.sh redis-0`

### 4. 改密码

先在**当前主**改 Redis，再改 Secret，最后滚动重启：

```bash
PRI=$(kubectl get cm redis-topology -o jsonpath='{.data.primary-pod}')
OLD=$(kubectl get secret redis-auth -o jsonpath='{.data.password}' | base64 -d)

kubectl exec "$PRI" -c redis -- redis-cli -a "$OLD" --no-auth-warning \
  CONFIG SET requirepass '新密码'
kubectl exec "$PRI" -c redis -- redis-cli -a '新密码' --no-auth-warning \
  CONFIG SET masterauth '新密码'
kubectl exec "$PRI" -c redis -- redis-cli -a '新密码' --no-auth-warning CONFIG REWRITE

# 从库也要对齐 masterauth（controller 会 REPLICAOF 重连）
for p in $(kubectl get pod -l app=redis -o jsonpath='{.items[*].metadata.name}'); do
  [ "$p" = "$PRI" ] && continue
  kubectl exec "$p" -c redis -- redis-cli -a "$OLD" --no-auth-warning \
    CONFIG SET requirepass '新密码' masterauth '新密码' || true
  kubectl exec "$p" -c redis -- redis-cli -a '新密码' --no-auth-warning CONFIG REWRITE || true
done

kubectl patch secret redis-auth --type merge -p '{"stringData":{"password":"新密码"}}'
kubectl rollout restart deploy/redis-controller
kubectl rollout restart sts/redis
```

### 5. 注意

- 这是主从 + 自研 controller，适合实验；生产大规模 HA 建议 Redis Sentinel / Operator。
- 客户端应连 Service `redis` 或 Gateway VIP，不要直连 Pod IP。
- 删 STS 不会删 PVC；清理残留盘见 `kubectl get pvc | grep redis`。
- 部署前改掉 Secret `redis-auth` 默认密码。
