1. 安装 MySQL Operator

helm repo add mysql-operator https://mysql.github.io/mysql-operator/
helm repo update
helm install mysql-operator mysql-operator/mysql-operator \
  --namespace mysql-operator \
  --create-namespace


确认 CRD 已就绪：
kubectl get crd | grep -E "innodbclusters|mysqlbackups"


2. 创建分区
kubectl create namespace dev
kubectl create namespace test
kubectl create namespace prod


3. 创建 root 凭证 Secret
# 每个环境独立的 root 凭证，密码必须不同
kubectl -n dev  create secret generic mysql-root-secret \
  --from-literal=rootUser=root --from-literal=rootHost='%' \
  --from-literal=rootPassword='<dev-强密码>'

kubectl -n test create secret generic mysql-root-secret \
  --from-literal=rootUser=root --from-literal=rootHost='%' \
  --from-literal=rootPassword='<test-强密码>'

kubectl -n prod create secret generic mysql-root-secret \
  --from-literal=rootUser=root --from-literal=rootHost='%' \
  --from-literal=rootPassword='<prod-强密码>'


4. 三套 InnoDBCluster 定义
apiVersion: mysql.oracle.com/v2
kind: InnoDBCluster
metadata:
  name: mysql-cluster
  namespace: dev
spec:
  secretName: mysql-root-secret
  tlsUseSelfSigned: true
  instances: 3
  version: "8.4.0"
  router:
    instances: 1
  datadirVolumeClaimTemplate:
    accessModes: ["ReadWriteOnce"]
    storageClassName: ceph-rbd
    resources:
      requests:
        storage: 20Gi
  podSpec:
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 2Gi