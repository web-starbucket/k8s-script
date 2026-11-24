# Apollo 配置中心部署

> 目标：Apollo Portal、ConfigService、AdminService **全部部署在 Kubernetes `prod` namespace**。Portal 中维护 DEV、GRAY（映射 Apollo UAT）、PRO 三个逻辑环境；每个逻辑环境独立 ConfigDB。业务应用按环境连接对应 Meta Service。
>
> 本目录使用 Apollo 官方 Helm Chart **0.12.0 / Apollo 3.0.0** 的 Kubernetes 原生服务发现模式。配置尚未在此工作区连接目标集群实测。values 中的数据库密码必须在部署机本地填写并保护，禁止提交到 Git。

## 架构

```text
业务 DEV ── ENV=DEV ──► Apollo ConfigService DEV ──► ApolloConfigDB_DEV
业务 GRAY ─ ENV=UAT ──► Apollo ConfigService UAT ──► ApolloConfigDB_GRAY
业务 PRO ── ENV=PRO ──► Apollo ConfigService PRO ──► ApolloConfigDB_PRO
                                  │
                         Portal（prod namespace）
                                  │
                    现有 MySQL Operator Service mysql-cluster.prod:6446（读写入口）
                                  │
                  MySQL StatefulSet PVC 使用 ceph-rbd
```

- Apollo 各服务无状态，不创建应用 PVC；持久数据保存在 MySQL。
- Apollo 官方要求每个逻辑环境一套 `ApolloConfigDB`，Portal 共用一套 `ApolloPortalDB`。
- Kubernetes 部署 namespace 与 Apollo 逻辑环境相互独立：gray 业务对应 Apollo UAT，但 MySQL schema 可以命名为 `ApolloConfigDB_GRAY`。
- ConfigService/AdminService 由 Helm 部署为多个 Pod，经各自 ClusterIP Service 提供稳定入口。业务服务注册发现仍使用 Kubernetes Service/Nacos 等，Apollo 本身不是业务注册中心。

## 文件

| 文件 | 用途 |
|---|---|
| `values-service-dev.yaml` | DEV ConfigService/AdminService，DB `ApolloConfigDB_DEV` |
| `values-service-gray.yaml` | UAT（灰度）ConfigService/AdminService，DB `ApolloConfigDB_GRAY` |
| `values-service-prod.yaml` | PRO ConfigService/AdminService，DB `ApolloConfigDB_PRO` |
| `values-portal.yaml` | Portal，两副本，配置三个环境 Meta Service |
| `httproute-portal.yaml` | 通过现有 `default/eg` HTTPS Gateway 暴露 Portal |

## 1. 前置检查

确认现有 MySQL 和 Ceph RBD 正常，Apollo namespace 使用 `prod`：

```bash
kubectl get ns prod
kubectl get sc ceph-rbd
kubectl -n prod get svc mysql-cluster
kubectl -n default get pods -l app=mysql -o wide
helm version
```

MySQL 地址应为 `mysql-cluster.prod.svc.cluster.local:6446`。现有 MySQL 使用 Ceph RBD PVC，因此 Apollo 数据最终存于 MySQL 的 RBD 卷；不要让 Apollo Pod 共享挂载 MySQL 数据目录。

## 2. 创建 MySQL 数据库并导入官方 SQL

Apollo 官方需要四个 schema：`ApolloPortalDB`、`ApolloConfigDB_DEV`、`ApolloConfigDB_GRAY`、`ApolloConfigDB_PRO`。从 Apollo v3.0.0 下载：

```bash
mkdir -p /tmp/apollo-sql-3.0.0 && cd /tmp/apollo-sql-3.0.0
curl -fL -o apolloconfigdb.sql \
  https://raw.githubusercontent.com/apolloconfig/apollo/v3.0.0/scripts/sql/profiles/mysql-default/apolloconfigdb.sql
curl -fL -o apolloportaldb.sql \
  https://raw.githubusercontent.com/apolloconfig/apollo/v3.0.0/scripts/sql/profiles/mysql-default/apolloportaldb.sql
```

只对**新建的空数据库**导入。ConfigDB SQL 含 `DROP TABLE`，重导会清表。分别复制 SQL 并替换 schema 名：

```bash
sed 's/ApolloConfigDB/ApolloConfigDB_DEV/g' apolloconfigdb.sql > apolloconfigdb-dev.sql
sed 's/ApolloConfigDB/ApolloConfigDB_GRAY/g' apolloconfigdb.sql > apolloconfigdb-gray.sql
sed 's/ApolloConfigDB/ApolloConfigDB_PRO/g' apolloconfigdb.sql > apolloconfigdb-pro.sql
```

在 Navicat 或 MySQL 客户端连接现有 MySQL，先为每个 schema 创建专用用户并授权，再导入 `apolloportaldb.sql` 一次，以及三份环境 ConfigDB SQL。密码用强随机值，不要写进本文档或 Git。Gray 的数据库名可以叫 `ApolloConfigDB_GRAY`，但 Apollo 客户端的环境值仍是 `UAT`。

验证数据库和表：

```sql
SHOW TABLES FROM ApolloPortalDB;
SHOW TABLES FROM ApolloConfigDB_DEV;
SHOW TABLES FROM ApolloConfigDB_GRAY;
SHOW TABLES FROM ApolloConfigDB_PRO;
```

## 3. 配置 Helm values

将本目录四个 `values-*.yaml` 复制到部署机受保护目录，填写第 2 步对应的 DB 用户和密码：

```bash
mkdir -p /opt/service/k8s-script/install-k8s/apollo
cp values-*.yaml /opt/service/k8s-script/install-k8s/apollo/
chmod 600 /opt/service/k8s-script/install-k8s/apollo/values-*.yaml
```

注意：官方 chart 会将 DB 凭据写入 Helm release 数据及 Apollo 配置资源；有更高安全要求时，应改用 Secret 注入方案并评审 chart 模板。

## 4. 镜像

所有 Apollo 镜像统一从 Starbucket 拉取。请先将以下 3 个上游镜像同步到私有仓库：

```text
docker.io/apolloconfig/apollo-configservice:3.0.0
  → registry.cn-global.starbucket.com.cn/starbucket/docker.io/apolloconfig/apollo-configservice:3.0.0

docker.io/apolloconfig/apollo-adminservice:3.0.0
  → registry.cn-global.starbucket.com.cn/starbucket/docker.io/apolloconfig/apollo-adminservice:3.0.0

docker.io/apolloconfig/apollo-portal:3.0.0
  → registry.cn-global.starbucket.com.cn/starbucket/docker.io/apolloconfig/apollo-portal:3.0.0
```

三个镜像地址已写入对应 values 文件的 `image.repository`/`image.tag`。只有确认目标仓库中的三个 tag 均存在后才部署。

## 5. 安装 Apollo（所有 release 都在 prod）

Apollo Portal、三个环境的 ConfigService/AdminService 全部安装在已有 `prod` namespace；release 名不同，用于区分组件和环境：

```bash
helm repo add apollo https://charts.apolloconfig.com
helm repo update
helm search repo apollo --versions
```

确认 `apollo-service` 和 `apollo-portal` chart 0.12.0 可用后执行：

```bash
helm upgrade --install apollo-service-dev apollo/apollo-service \
  --version 0.12.0 -n prod \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-dev.yaml \
  --wait --timeout 10m

helm upgrade --install apollo-service-gray apollo/apollo-service \
  --version 0.12.0 -n prod \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-gray.yaml \
  --wait --timeout 10m

helm upgrade --install apollo-service-prod apollo/apollo-service \
  --version 0.12.0 -n prod \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-prod.yaml \
  --wait --timeout 10m

helm upgrade --install apollo-portal apollo/apollo-portal \
  --version 0.12.0 -n prod \
  -f /opt/service/k8s-script/install-k8s/apollo/values-portal.yaml \
  --wait --timeout 10m
```

Portal Meta Server values 应为：

```text
dev: http://apollo-service-dev-apollo-configservice.prod.svc.cluster.local:8080
uat: http://apollo-service-gray-apollo-configservice.prod.svc.cluster.local:8080
pro: http://apollo-service-prod-apollo-configservice.prod.svc.cluster.local:8080
```

## 6. 暴露 Portal 与验证

Portal Service 保持 ClusterIP，通过已有 Gateway 暴露。`httproute-portal.yaml` 已设置 `namespace: prod`；按实际 Portal 域名、Gateway listener 和证书调整后应用：

```bash
kubectl apply -f httproute-portal.yaml
kubectl -n prod describe httproute apollo-portal
kubectl -n prod get pods,svc,endpoints -o wide
```

ConfigService/AdminService 保持集群内 ClusterIP，不要直接暴露公网。验证 Portal 可访问、三个环境服务 Pod Ready、EndPoints 中有健康实例。可查看日志：

```bash
kubectl -n prod logs deploy/apollo-service-dev-apollo-configservice --tail=100
kubectl -n prod logs deploy/apollo-service-gray-apollo-configservice --tail=100
kubectl -n prod logs deploy/apollo-service-prod-apollo-configservice --tail=100
kubectl -n prod logs deploy/apollo-portal --tail=100
```

## 7. 后端应用接入

Java 应用引入与项目兼容的 Apollo Client，配置 `APP_ID`、Apollo 环境和对应 Meta Service。示例：

```yaml
env:
  - name: APP_ID
    value: order-service
  - name: ENV
    value: UAT  # gray namespace 映射的 Apollo 逻辑环境
  - name: APOLLO_META
    value: http://apollo-service-gray-apollo-configservice.prod.svc.cluster.local:8080
```

DEV 使用 `ENV=DEV` 和 `apollo-service-dev-apollo-configservice.prod.svc.cluster.local:8080`；PRO 使用 `ENV=PRO` 和 `apollo-service-prod-apollo-configservice.prod.svc.cluster.local:8080`。Apollo 管理配置和向客户端下发配置；业务 Pod 间调用仍用 Kubernetes Service 或 Nacos 等服务发现。

## 8. 持久化与安全

- Apollo 配置、发布历史和 Portal 数据在 MySQL，不在 Apollo Pod 文件系统；MySQL 的 PVC 使用 Ceph RBD。
- 现有 MySQL 是异步主从/自定义切换，不能保证零数据丢失。定期备份四个 Apollo schema，并做恢复演练。
- 官方 SQL 只导入空 schema；升级前备份并使用匹配 Apollo 版本的 schema 脚本。
- Apollo 官方 Portal SQL 初始化包含默认用户 `apollo`。上线前应修改默认凭据或接入公司 SSO。
- 当前 Helms values 含密码，应限制文件权限、不提交 Git；Portal 及 Config/Admin 服务仅向授权内网开放。