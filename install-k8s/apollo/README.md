# Apollo 配置中心（Helm + MySQL + Ceph RBD）

Apollo 是配置中心，不是文件型数据库。ConfigService、AdminService、Portal 服务本身是无状态 Pod；配置、发布历史、Portal 用户等持久数据存在 MySQL。此集群现有 MySQL StatefulSet 使用 `ceph-rbd` PVC，因此 **Apollo 数据通过 MySQL 落盘到 Ceph RBD**，不要给 Apollo 应用 Pod 共享挂载 MySQL 数据目录，也不需要给 Apollo 服务 Pod 单独创建 PVC。

> 本目录按官方 Apollo Helm Chart 的 Kubernetes 原生服务发现模式整理。**Helm chart、官方 SQL 和 values 文件已检查，但尚未在你的集群执行 `helm template` 或部署验证。**部署前先渲染检查 Chart 资源和数据库配置，且需确认 MySQL 中数据库/用户和 SQL 已就绪。Helm values 中包含密码占位字段，请勿把真实密码提交 Git。

本目录 Helm values 使用 Apollo 官方 Helm Chart **0.12.0 / Apollo 3.0.0**，启用 Apollo 官方 Kubernetes 原生服务发现 profile（`github,kubernetes`），不使用 Eureka。官方文档说明 Kubernetes 原生发现从 Apollo 1.7.0 起提供，服务 chart 可将 ConfigService/AdminService 以多副本 Deployment + ClusterIP Service 暴露：

- [Apollo 官方分布式部署文档](https://www.apolloconfig.com/#/zh/deployment/distributed-deployment-guide)
- [Apollo 官方 Helm 仓库](https://charts.apolloconfig.com)
- [Apollo 官方数据库 SQL（v3.0.0）](https://github.com/apolloconfig/apollo/tree/v3.0.0/scripts/sql/profiles/mysql-default)

## 1. 拓扑与环境映射

Apollo 的逻辑环境不是 Kubernetes namespace。此方案将 gray Kubernetes namespace 映射到 Apollo 内置逻辑环境 UAT（如果要自定义环境名 `gray`，需另走 Apollo 自定义环境配置，此处只自定义数据库 schema 名）。映射如下：

| Kubernetes namespace | Apollo 内置逻辑环境 | 独立数据库 | Helm release |
|---|---|---|---|
| `apollo-dev` | `dev` | `ApolloConfigDB_DEV` | `apollo-service-dev` |
| `apollo-gray` | `uat`（灰度/预发） | `ApolloConfigDB_GRAY` | `apollo-service-gray` |
| `apollo-prod` | `pro` | `ApolloConfigDB_PRO` | `apollo-service-prod` |
| `apollo-portal` | 一个共享 Portal | `ApolloPortalDB` | `apollo-portal` |

```text
客户端 DEV ──► apollo-dev/apollo-service-dev-apollo-configservice (ClusterIP)
客户端 GRAY/UAT ──► apollo-gray/apollo-service-gray-apollo-configservice (ClusterIP)
客户端 PRO ──► apollo-prod/apollo-service-prod-apollo-configservice (ClusterIP)

Apollo Portal (2 replicas) ──► 各环境 Meta Service
各环境 ConfigService/AdminService ──► 对应环境的 ApolloConfigDB
所有 Apollo DB ──► 现有 mysql.default.svc.cluster.local:3306
现有 MySQL StatefulSet 的数据 PVC ──► ceph-rbd
```

同环境多 Pod 不会因注册冲突：Apollo 3.0.0 官方 Chart 使用 Kubernetes 原生服务发现。客户端/Portal访问稳定的 Service DNS，Service 把连接负载均衡到该环境的 Ready Pod。各环境使用独立 namespace、Service 和 ConfigDB；**不要把 dev/gray/prod 的 ConfigDB 混成同一数据库**。

> 若业务要求 Apollo 环境名严格叫 `gray`，而不是内置环境 `uat`，需按 Apollo 官方自定义环境流程配置 Portal 和客户端。这里采用兼容性更好的映射：K8s `apollo-gray` ↔ Apollo UAT。

## 2. Ceph RBD 如何承载 Apollo 数据

Apollo 应用 Pod 没有需共享的本地数据目录。持久数据在数据库：

- `ApolloConfigDB_DEV`、`ApolloConfigDB_GRAY`（Apollo UAT 环境）、`ApolloConfigDB_PRO` 分别保存各环境配置、发布记录等。
- `ApolloPortalDB` 保存 Portal 用户、权限、全局信息及环境 Meta 地址。
- 现有 MySQL 的 `data-mysql-0` / `data-mysql-1` 使用各自 Ceph RBD PVC；MySQL 主从复制由现有部署负责。

这表示 Apollo 数据通过 MySQL 的 Ceph RBD 卷持久化，不是 Apollo ConfigService Pod 直接挂 Ceph PVC。MySQL 当前为异步主从与自定义故障切换，并不承诺零数据丢失；Apollo 可用性/一致性受该 MySQL 架构约束。请单独备份 MySQL，并定期演练恢复。

## 3. 前置检查

```bash
kubectl get sc ceph-rbd
kubectl -n default get svc mysql
kubectl -n default get pods -l app=mysql -o wide
```

确认 MySQL 主库 Service 为 `mysql.default.svc.cluster.local:3306`，Kubernetes 版本 1.33，且 Helm 3 可用。Apollo 官方服务端要求 Java 17+；使用官方容器镜像，无需在 K8s 节点手动安装 Java。

将 `values-service-dev.yaml`、`values-service-gray.yaml`、`values-service-prod.yaml` 和 `values-portal.yaml` 复制到受保护的运维目录，设置权限 `chmod 600`。**Helm values 中的 DB 密码会进入 Helm release 数据和 chart 生成的配置资源**，不要提交 Git，不要把真实密码贴到工单/聊天中。更高安全要求应改造成 External Secrets/Secret 注入版本，并评审 Apollo Chart 模板。

## 4. 创建 Apollo 数据库

Apollo 官方要求一个共享 PortalDB，以及**每个 Apollo 逻辑环境一套 ConfigDB**。这里有四个 schema：`ApolloPortalDB`、`ApolloConfigDB_DEV`、`ApolloConfigDB_GRAY`（对应 Apollo UAT）、`ApolloConfigDB_PRO`。Schema 名称可自定义，Portal 中的 Apollo 环境名仍是 UAT。

### 4.1 创建数据库账号和空库

在现有 MySQL 主库用管理员账号执行；密码替换为强随机值并通过受控通道录入：

```sql
CREATE DATABASE ApolloPortalDB DEFAULT CHARACTER SET utf8mb4;
CREATE DATABASE ApolloConfigDB_DEV DEFAULT CHARACTER SET utf8mb4;
CREATE DATABASE ApolloConfigDB_GRAY DEFAULT CHARACTER SET utf8mb4;
CREATE DATABASE ApolloConfigDB_PRO DEFAULT CHARACTER SET utf8mb4;

CREATE USER 'apollo_portal'@'%' IDENTIFIED BY '<替换为对应的强随机密码>';
GRANT ALL PRIVILEGES ON ApolloPortalDB.* TO 'apollo_portal'@'%';

CREATE USER 'apollo_dev'@'%' IDENTIFIED BY '<替换为对应的强随机密码>';
GRANT ALL PRIVILEGES ON ApolloConfigDB_DEV.* TO 'apollo_dev'@'%';

CREATE USER 'apollo_gray'@'%' IDENTIFIED BY '<gray强随机密码>';
GRANT ALL PRIVILEGES ON ApolloConfigDB_GRAY.* TO 'apollo_gray'@'%';

CREATE USER 'apollo_prod'@'%' IDENTIFIED BY '<替换为对应的强随机密码>';
GRANT ALL PRIVILEGES ON ApolloConfigDB_PRO.* TO 'apollo_prod'@'%';
FLUSH PRIVILEGES;
```

如果库/用户已存在，不要盲目重建或覆盖密码；先核对已有状态。Apollo 官方 SQL 含有 `DROP TABLE`，**只能导入新建的空 schema，重导会清表**。

### 4.2 下载并导入官方 v3.0.0 SQL

在管理机下载 Apollo **同为 3.0.0** 的 SQL：

```bash
mkdir -p /tmp/apollo-sql-3.0.0 && cd /tmp/apollo-sql-3.0.0
curl -fL -o apolloconfigdb.sql \
  https://raw.githubusercontent.com/apolloconfig/apollo/v3.0.0/scripts/sql/profiles/mysql-default/apolloconfigdb.sql
curl -fL -o apolloportaldb.sql \
  https://raw.githubusercontent.com/apolloconfig/apollo/v3.0.0/scripts/sql/profiles/mysql-default/apolloportaldb.sql
```

Apollo ConfigDB SQL 默认会 `CREATE DATABASE/USE ApolloConfigDB`。为三环境隔离 schema，对文件副本中的 `ApolloConfigDB` 做环境名替换，然后导入空库；不要直接改源 SQL，也不要对已有生产库执行：

```bash
sed 's/ApolloConfigDB/ApolloConfigDB_DEV/g' apolloconfigdb.sql > apolloconfigdb-dev.sql
sed 's/ApolloConfigDB/ApolloConfigDB_GRAY/g' apolloconfigdb.sql > apolloconfigdb-gray.sql
sed 's/ApolloConfigDB/ApolloConfigDB_PRO/g' apolloconfigdb.sql > apolloconfigdb-pro.sql
```

通过受控 MySQL 管理连接分别导入：

```bash
mysql -h mysql.default.svc.cluster.local -u <管理员用户> -p < apolloportaldb.sql
mysql -h mysql.default.svc.cluster.local -u <管理员用户> -p < apolloconfigdb-dev.sql
mysql -h mysql.default.svc.cluster.local -u <管理员用户> -p < apolloconfigdb-gray.sql
mysql -h mysql.default.svc.cluster.local -u <管理员用户> -p < apolloconfigdb-pro.sql
```

验证各库表存在：

```sql
SHOW TABLES FROM ApolloPortalDB;
SHOW TABLES FROM ApolloConfigDB_DEV;
SHOW TABLES FROM ApolloConfigDB_GRAY;
SHOW TABLES FROM ApolloConfigDB_PRO;
```

## 5. 修改 Helm values

把以下占位密码换成第 4 步创建的数据库用户密码。三个 service values 中 DB 主机均为现有 `mysql.default.svc.cluster.local`；Portal 配置中已列出 DEV/UAT/PRO 对应的 Meta Service DNS。

由于 chart values 有凭据占位，保护文件：

```bash
mkdir -p /opt/service/k8s-script/install-k8s/apollo
cp values-*.yaml /opt/service/k8s-script/install-k8s/apollo/
chmod 600 /opt/service/k8s-script/install-k8s/apollo/values-*.yaml
```

文件在本目录：

- `values-service-dev.yaml` → namespace `apollo-dev`，ConfigDB `ApolloConfigDB_DEV`
- `values-service-gray.yaml` → namespace `apollo-gray`，Apollo UAT，ConfigDB `ApolloConfigDB_GRAY`
- `values-service-prod.yaml` → namespace `apollo-prod`，Apollo PRO，ConfigDB `ApolloConfigDB_PRO`
- `values-portal.yaml` → namespace `apollo-portal`，PortalDB `ApolloPortalDB`，Portal 两副本

Helm Chart `apollo-service` 负责该环境的 ConfigService + AdminService；两者默认各 2 副本，ClusterIP Service 稳定转发。Portal 由单独 chart 安装。Chart Release 0.12.0 对应 Apollo 3.0.0；先检查仓库列表并固定版本。

## 6. 安装 Helm Chart

```bash
helm repo add apollo https://charts.apolloconfig.com
helm repo update
helm search repo apollo --versions
```

确认 `apollo-service` 和 `apollo-portal` 的 chart 0.12.0 存在后安装。单个环境示例：

```bash
helm upgrade --install apollo-service-dev apollo/apollo-service \
  --version 0.12.0 -n apollo-dev --create-namespace \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-dev.yaml \
  --wait --timeout 10m
```

安装另外两个环境：

```bash
helm upgrade --install apollo-service-gray apollo/apollo-service \
  --version 0.12.0 -n apollo-gray --create-namespace \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-gray.yaml \
  --wait --timeout 10m

helm upgrade --install apollo-service-prod apollo/apollo-service \
  --version 0.12.0 -n apollo-prod --create-namespace \
  -f /opt/service/k8s-script/install-k8s/apollo/values-service-prod.yaml \
  --wait --timeout 10m
```

Portal：

```bash
helm upgrade --install apollo-portal apollo/apollo-portal \
  --version 0.12.0 -n apollo-portal --create-namespace \
  -f /opt/service/k8s-script/install-k8s/apollo/values-portal.yaml \
  --wait --timeout 10m
```

镜像拉取若受限，先确认私有镜像仓库中存在 Apollo 3.0.0 对应镜像，并在 values 的 `image.repository` 配置实际仓库；不要使用旧版社区 chart 中未经验证的快照镜像。

## 7. Gateway 暴露 Portal

Portal Service 仅需内部访问，外部 Web UI 通过 Gateway 暴露。先确认 `apollo-portal` Service 名/端口：

```bash
kubectl -n apollo-portal get svc
```

将 `httproute-portal.yaml` 中 hostname 按实际域名修改，并确认 `default/eg` Gateway Listener 允许 `apollo-portal` namespace 的 HTTPRoute，再应用：

```bash
kubectl apply -f httproute-portal.yaml
kubectl -n apollo-portal describe httproute apollo-portal
```

ConfigService/AdminService 保持 ClusterIP，不要直接暴露公网；Apollo 客户端需能够访问相应环境 ConfigService 的 ClusterIP Service DNS。

## 8. 验证多副本和服务发现

```bash
kubectl -n apollo-dev get pods,svc,endpoints -o wide
kubectl -n apollo-gray get pods,svc,endpoints -o wide
kubectl -n apollo-prod get pods,svc,endpoints -o wide
kubectl -n apollo-portal get pods,svc -o wide
```

每个 ConfigService/AdminService Deployment 的 Ready 副本应为 2/2。Apollo Kubernetes discovery 使用对应 ClusterIP Service 发现同环境实例，不依赖 StatefulSet 固定 Pod 名，也不会跨环境互相注册。不同环境的 Release/namespace/ConfigDB 相互隔离。多副本不能超出可调度节点资源；集群目前工作节点数量有限，反亲和设置为 preferred，仅为尽量分散，不保证每个 Pod 一定在不同 Worker。

查看服务日志：

```bash
kubectl -n apollo-dev logs deploy/apollo-service-dev-apollo-configservice --tail=100
kubectl -n apollo-dev logs deploy/apollo-service-dev-apollo-adminservice --tail=100
kubectl -n apollo-portal logs deploy/apollo-portal --tail=100
```

Helm 渲染的 Meta Server 可从 Portal values 查看，或按官方说明使用安装输出。Apollo 官方 Helm Chart 的 Kubernetes discovery 配置是 `configService.config.profiles` / `adminService.config.profiles` 的 `github,kubernetes`。

### 后端应用接入 Apollo

Apollo 负责**配置管理/配置下发**，不是通用业务服务注册中心。业务 Pod 不向 Apollo 注册自己的 HTTP/RPC 地址；ConfigService/AdminService 多副本由 Kubernetes 原生服务发现和各自 ClusterIP Service 处理。业务应用间注册/发现仍使用 Kubernetes Service DNS，或 Nacos/Consul 等服务注册中心。

#### Java/Spring Boot 客户端

添加 Apollo Java Client（选择与项目 Java/Spring Boot 兼容的 client 版本）：

```xml
<dependency>
  <groupId>com.ctrip.framework.apollo</groupId>
  <artifactId>apollo-client</artifactId>
  <version>${apollo.client.version}</version>
</dependency>
```

Spring 使用示例：

```java
@SpringBootApplication
@EnableApolloConfig
public class Application { }

@Component
public class FeatureConfig {
    @Value("${feature.enabled:false}")
    private boolean enabled;
}
```

或者使用 API：

```java
Config config = ConfigService.getAppConfig();
String value = config.getProperty("feature.enabled", "false");
```

`APP_ID` 标识应用；`ENV` 和 `APOLLO_META` 决定环境及 Meta Service。建议在 Deployment 通过环境变量注入，不要把 Meta 地址写成 Pod IP。Gray K8s namespace 在本方案映射 Apollo 的内置 UAT 环境：

```yaml
env:
  - name: APP_ID
    value: order-service
  - name: ENV
    value: UAT
  - name: APOLLO_META
    value: http://apollo-service-gray-apollo-configservice.apollo-gray.svc.cluster.local:8080
```

其他环境：

- `dev` namespace：`ENV=DEV`，Meta `http://apollo-service-dev-apollo-configservice.apollo-dev.svc.cluster.local:8080`
- `prod` namespace：`ENV=PRO`，Meta `http://apollo-service-prod-apollo-configservice.apollo-prod.svc.cluster.local:8080`

ConfigService Service 会把客户端请求负载均衡到该环境 Ready 的 ConfigService Pod。Apollo SDK 从 Apollo 获取配置并通过长轮询接收变更；多副本应用使用相同 `APP_ID` 和环境时获取同一环境配置是正常的，不会发生服务注册冲突。Apollo **不负责**把业务 Pod 注册成可互相调用的服务端点。业务调用仍通过 Kubernetes Service，例如 `http://order-service.gray.svc.cluster.local:8080`；若业务需注册中心功能，另用 Nacos 等。

如果业务客户端运行在集群外，不能使用上述 `.svc.cluster.local` 地址；需为 ConfigService 配置可达的内网域名/VIP，并确保 Apollo 返回给客户端的 Meta 地址从客户端网络可达。更多客户端配置方式见[Apollo 官方 Java 客户端指南](https://github.com/apolloconfig/apollo/blob/master/docs/zh/client/java-sdk-user-guide.md)。

## 9. Ceph 与持久化说明

Apollo 三类应用服务均无状态，不需要 `volumeClaimTemplates`；**Ceph 持久化在已有 MySQL**：每个 MySQL StatefulSet 副本有自己的 `ceph-rbd` RWO PVC，数据库复制由当前 MySQL 主从机制完成。不要把同一个 Ceph RBD PVC 共享挂载给多份 Apollo 或 MySQL Pod。

Apollo HA 由多副本应用 + Kubernetes Service + MySQL 数据库可用性共同组成。当前 MySQL 是异步主从/自定义切换方案，不承诺零数据丢失；生产需额外做 MySQL 备份与恢复演练。Apollo 发布的配置数据在数据库，不在应用容器本地磁盘。

## 10. 关键注意

- Apollo 官方每个环境独立 ApolloConfigDB；PortalDB 共享一套。
- `gray` K8s namespace 在本方案映射 Apollo 内置 UAT；客户端环境值使用 `UAT`（大小写按官方说明不敏感）。`ApolloConfigDB_GRAY` 只是 MySQL schema 名称，不会把 Apollo 逻辑环境改名为 GRAY。
- Apollo 自定义环境名需要额外设置 Portal 支持环境列表、Meta Server 映射以及客户端环境；不要仅把数据库名改成 `gray` 就认为环境已创建。
- `ApolloPortalDB` 官方 SQL 初始化的默认管理员是 `apollo`。首次上线前更改默认凭据/接入 SSO，并设置合理 `superAdmin`。
- Helm chart 会将数据库凭据渲染到 Apollo properties ConfigMap，并存在 Helm release values 中。保护 values 文件、限制 namespace RBAC；高安全要求需改造为 Secret 注入。
- SQL 包含 `DROP TABLE`，只对新建空数据库导入；升级 Apollo 时严格使用目标版本对应的数据库升级脚本，先备份。