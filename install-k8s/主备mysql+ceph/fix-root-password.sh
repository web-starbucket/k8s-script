#!/usr/bin/env bash
# 修复 Pod 内 root 与 Secret 不一致（空密码 / super_read_only 拦 ALTER）
# 用法: bash fix-root-password.sh mysql-1
set -euo pipefail
NS="${NS:-default}"
POD="${1:?用法: $0 mysql-1}"
PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.root-password}' | base64 -d)"
REPL_PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.replication-password}' | base64 -d)"
SOCK="/var/run/mysqld/mysqld.sock"

echo "▸ Secret root 密码长度=${#PW}"
if kubectl -n "${NS}" exec "${POD}" -c mysql -- \
  mysql --protocol=SOCKET --socket="${SOCK}" -uroot -p"${PW}" -e "SELECT 1" >/dev/null 2>&1; then
  echo "✓ ${POD} 已能用 Secret 密码登录，无需修复"
  exit 0
fi

echo "▸ Secret 密码不通，尝试空密码改密（并关闭 super_read_only）..."
kubectl -n "${NS}" exec "${POD}" -c mysql -- \
  mysql --protocol=SOCKET --socket="${SOCK}" -uroot -e "
    SET GLOBAL super_read_only=OFF;
    SET GLOBAL read_only=OFF;
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${PW}';
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${PW}';
    ALTER USER 'root'@'%' IDENTIFIED BY '${PW}';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${PW}';
    ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${PW}';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
    CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${REPL_PW}';
    GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
    FLUSH PRIVILEGES;
    SELECT 'password-fixed' AS status;"

kubectl -n "${NS}" exec "${POD}" -c mysql -- \
  mysql --protocol=SOCKET --socket="${SOCK}" -uroot -p"${PW}" -e "SELECT @@hostname AS ok;"
echo "✓ ${POD} root 已与 Secret 对齐"
