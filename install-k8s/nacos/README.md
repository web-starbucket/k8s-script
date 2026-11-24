# Nacos 集群（Kubernetes + MySQL + Ceph RBD）

本目录提供 3 节点 Nacos StatefulSet 配置。Nacos 使用外部 MySQL 保存配置/命名空间等持久化数据；MySQL 由现有 `mysql` Service 提供，数据卷沿用该 MySQL 部署自己的 Ceph RBD PVC。Nacos 节点本身不共用数据卷。

> 当前 MySQL Service 位于 `default` namespace，故配置使用 `mysql.default.svc.cluster.local:3306`。如果数据库 Service/namespace 不同，需相应修改 `nacos.yaml` 中的 `MYSQL_SERVICE_HOST`。

## 1. 架构与调用方式

```text
Nacos 客户端 / Spring Cloud / Dubbo
             │
             ├──访问 Nacos: nacos.nacos.svc.cluster.local:8848
             │                  ├── nacos-0
             │                  ├── nacos-1
             │                  └── nacos-2
             │                        │
             │                        └──共享 MySQL 数据库 nacos_config
             │
             └──服务发现：获取某服务的健康实例列表
                         └──客户端负载均衡器选一个实例调用
```

Nacos 是**注册中心/服务发现控制面，不是业务请求代理**。同一服务的多个应用 Pod 会作为多个实例注册到 Nacos；客户端拿到实例列表后，由客户端负载均衡器（如 Spring Cloud LoadBalancer、Dubbo）根据策略选择实例。正常情况下单次调用选择一个实例，不是 Nacos 把一次请求同时转发给多个 Pod。

若业务直接请求 Kubernetes Service DNS，则由 Kubernetes Service 在其后端 Pod 间转发，不经过 Nacos。两种服务发现方式可并存，但应用应明确使用哪一种。

## 2. 版本与端口

| 项目 | 配置 |
|---|---|
| Nacos | 2.4.3（镜像 tag 固定；部署前按组织镜像源确认可拉取） |
| 副本 | 3 |
| HTTP/API/控制台 | 8848 |
| 客户端 gRPC | 9848（客户端访问 8848 时通常还会连接该端口） |
| 节点间 gRPC | 9849 |
| Raft | 7848（仅集群内部） |
| 数据库 | 外部 MySQL，库名 `nacos_config` |
| 持久卷 | Nacos 不使用共享 PVC；持久化数据在 MySQL，MySQL 使用各自 Ceph RBD PVC |

清单中的 Service 默认 `ClusterIP`，优先仅供集群内应用访问。若集群外客户端必须访问，需要同时暴露 8848 和 9848（例如 TCPRoute/NodePort/LB），并限制来源网络；只暴露 8848 可能导致 Nacos 2.x 客户端 gRPC 连接失败。9849/7848 不应对客户端或公网开放。

## 3. 前置条件

1. Kubernetes 能调度 3 个 Nacos Pod。要承受单个工作节点故障，建议至少 3 个可调度 Worker；清单使用软反亲和，因此节点不足时仍可能共置。
2. MySQL Service 可从 `nacos` namespace 访问：`mysql.default.svc.cluster.local:3306`。
3. MySQL 已创建 Nacos 专用数据库和用户，并导入**与 Nacos 2.4.3 对应的官方 MySQL schema**。不要直接把未初始化的空库交给 Nacos。
4. MySQL 用户有 `nacos_config` 库所需的 DDL/DML 权限。

### 初始化数据库

先在官方 Nacos **2.4.3** release/source package 中找到 `conf/mysql-schema.sql`，确认版本匹配后导入。以当前 MySQL Service 为例：

```sql
CREATE DATABASE nacos_config DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'nacos'@'%' IDENTIFIED BY '<强密码>';
GRANT ALL PRIVILEGES ON nacos_config.* TO 'nacos'@'%';
FLUSH PRIVILEGES;
```

用具备管理员权限的账号将该版本 `mysql-schema.sql` 导入 `nacos_config`。实际账号创建、授权请依照你们当前 MySQL 凭据管理流程操作，避免将密码写入 shell 历史或 Git。

## 4. 创建 Secrets 并部署

先创建命名空间和 Secret。以下仅示范交互式录入 DB 密码；不要提交真实值到仓库：

```bash
kubectl apply -f nacos.yaml --dry-run=client
kubectl create namespace nacos --dry-run=client -o yaml | kubectl apply -f -

read -rsp 'MySQL nacos 用户密码: ' NACOS_DB_PASSWORD; echo
kubectl -n nacos create secret generic nacos-db-auth \
  --from-literal=username=nacos \
  --from-literal=password="$NACOS_DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset NACOS_DB_PASSWORD

# 生成独立的 Nacos token key 和节点身份值，三节点共用同一 Secret
kubectl -n nacos create secret generic nacos-auth \
  --from-literal=token="$(openssl rand -base64 48)" \
  --from-literal=identity-key='serverIdentity' \
  --from-literal=identity-value="$(openssl rand -hex 24)" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f nacos.yaml
kubectl -n nacos rollout status statefulset/nacos --timeout=10m
kubectl -n nacos get pods,svc,pdb -o wide
```

清单默认镜像 `nacos/nacos-server:v2.4.3`。若 Docker Hub 不可达，应先将该版本镜像同步到认可的镜像仓库，再将 `nacos.yaml` 中镜像改为实际仓库地址；不要在未经校验时假定镜像代理上一定有该 tag。

## 5. 验证集群

```bash
kubectl -n nacos get pods -o wide
kubectl -n nacos get endpoints nacos nacos-headless
kubectl -n nacos logs nacos-0 --tail=100
kubectl -n nacos logs nacos-1 --tail=100
kubectl -n nacos logs nacos-2 --tail=100

# 集群内 HTTP 健康检查
kubectl -n nacos run nacos-curl --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://nacos.nacos.svc.cluster.local:8848/nacos/v1/console/health/readiness
```

预期 3 个 Pod 均 Ready；Nacos 控制台/HTTP 地址为 `http://nacos.nacos.svc.cluster.local:8848/nacos/`。控制台认证由 Nacos 鉴权配置管理，请部署后用受控的管理员凭据初始化，不要使用公开默认密码。

## 6. 服务注册与负载均衡说明

- 同服务多个 Pod 各自启动 Nacos 客户端，用相同的 `serviceName`、namespace/group 注册，但每个实例上报自己的 IP/端口。
- 消费者向 Nacos 查询健康实例列表，应用客户端负载均衡器选择其中一个实例；Nacos 不会在收到业务请求后充当反向代理，也不会自动把一条调用广播给所有实例。
- 具体均衡算法由客户端框架/配置决定（随机、轮询、权重等）；如果配置为广播、集群调用或应用代码并发调用多个实例，那是调用端行为，不是 Nacos 默认转发行为。
- 客户端应启用实例健康检查/心跳，并配置失败重试、超时和连接池；Nacos 集群健康不等于业务实例自身一定健康。
- 客户端必须使用 Nacos 2.x 对应的客户端版本，并能访问 8848 与客户端 gRPC 9848。

## 7. 运维与边界

```bash
# 扩缩容（维持奇数节点；建议先评估 Nacos 集群成员变更流程）
kubectl -n nacos scale statefulset nacos --replicas=3

# 状态及事件
kubectl -n nacos get pods -o wide
kubectl -n nacos describe pod nacos-0
kubectl -n nacos get events --sort-by=.lastTimestamp | tail -30
```

- `PodDisruptionBudget minAvailable: 2` 阻止自愿操作同时驱逐两个节点；不防硬件/网络故障。
- Nacos 集群元数据依赖 MySQL。如果 MySQL 是异步主从并可能丢失未复制事务，那么 Nacos 的持久化一致性/可用性也受它影响。
- MySQL 需要备份 `nacos_config`，备份应放在 Ceph 集群以外；Nacos 3 节点不是数据库备份。
- 更改 StatefulSet 的身份、服务名或集群环境变量前，先评估 Nacos 集群成员变更；不要简单地把已有 PVC 共享给多个 Nacos Pod。
- 安全组/防火墙仅允许应用节点访问 8848/9848、Nacos 节点间访问 9849/7848，以及 Nacos 到 MySQL 的 3306。
