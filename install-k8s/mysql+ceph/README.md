## MySQL：StatefulSet + Ceph RBD + 故障转移 + TCPRoute


### 1. 部署

```bash
kubectl apply -f mysql.yaml
kubectl apply -f mysql-controller.yaml
kubectl logs -f deploy/mysql-controller
```

状态行仅在变化时打印，例如：

```text
[08:24:08] 主 mysql-0 Ready  |  从 mysql-1 Ready 复制=正常 IO=ON SQL=ON 源=mysql-0.mysql-hl
```

### 2. 测故障转移

```bash
kubectl logs -f deploy/mysql-controller

# 宕掉当前主（例如 mysql-0）
kubectl delete pod mysql-0 --grace-period=0 --force
# 约 1–3s：升主 mysql-1

kubectl get cm mysql-topology -o jsonpath='{.data.primary-pod}{"\n"}'
kubectl get ep mysql
```

`mysql-0` 被 STS 拉起后会成为从库，**不会**再切回 `mysql-0`。要手工切回：`bash promote-replica.sh mysql-0`

三副本时把 STS `replicas: 3`，挂掉当前主会升其它存活节点。

### 3. 注意

- 从库也需开 `log-bin` + `log_replica_updates`（`mysql.yaml` 已配），否则升主后再挂回从库易缺事务。
- 复制报 1236（binlog 已 purge）时，用 `rebuild-replica.sh` 按当前主 dump 重建从库。
- 密码在 Secret `mysql-auth`，部署前改掉。
