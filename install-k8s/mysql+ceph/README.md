## MySQL：StatefulSet + Ceph RBD + 故障转移 + TCPRoute


### 1. 部署

```bash
kubectl apply -f mysql.yaml
kubectl apply -f mysql-controller.yaml
kubectl logs -f deploy/mysql-controller
```

状态行仅在变化时打印，例如：

```text
[08:24:08] 主 mysql-0 Ready  |  从 mysql-1 Ready 复制=正常 IO=ON SQL=ON 源=mysql-0.mysql-headless
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

# 查看当前主库实列
```
SELECT @@hostname, @@read_only, @@super_read_only;
```


### 3. 在线修改数据库账号密码
```
kubectl exec "$PRI" -c mysql -- mysql --protocol=SOCKET -uroot -p"$OLD" -e "
  ALTER USER 'root'@'localhost' IDENTIFIED BY 'remo@**123';
  ALTER USER 'root'@'%' IDENTIFIED BY 'remo@**123';
  ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY 'remo@**123';
  ALTER USER 'repl'@'%' IDENTIFIED BY 'remo@**123';
  FLUSH PRIVILEGES;"


# 更新实际的从库
kubectl exec mysql-0 -c mysql -- mysql --protocol=SOCKET -uroot -p'remo@**123' -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD='remo@**123';
  START REPLICA;"

kubectl patch secret mysql-auth --type merge -p '{"stringData":{
  "root-password":"remo@**123",
  "replication-password":"remo@**123"
}}'


kubectl rollout restart deploy/mysql-controller
kubectl rollout restart sts/mysql
kubectl logs -f deploy/mysql-controller
```

### 4. 删除残留从库pvc
查看使用
```
kubectl get pvc | grep mysql
kubectl get pod -l app=mysql -o wide
kubectl get sts mysql -o jsonpath='{.spec.replicas}{"\n"}'
```

删除未使用
```
kubectl delete pvc data-mysql-2 data-mysql-3
```

### 5. 注意

- 从库也需开 `log-bin` + `log_replica_updates`（`mysql.yaml` 已配），否则升主后再挂回从库易缺事务。
- 复制报 1236（binlog 已 purge）时，用 `rebuild-replica.sh` 按当前主 dump 重建从库。
- 密码在 Secret `mysql-auth`，部署前改掉。


