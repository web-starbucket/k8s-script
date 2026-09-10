#!/usr/bin/env bash
# 手工升主（failover 只在故障时自动切；不会自动回切）
set -euo pipefail
NS="${NS:-default}"
NEW="${1:-mysql-1}"
OLD="$(kubectl -n "${NS}" get cm mysql-topology -o jsonpath='{.data.primary-pod}' | tr -d '[:space:]')"
ROOT_PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.root-password}' | base64 -d)"
REPL_PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.replication-password}' | base64 -d)"

echo "▸ ${OLD} -> ${NEW}"
kubectl -n "${NS}" exec "${NEW}" -c mysql -- \
  mysql --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
  -uroot -p"${ROOT_PW}" -e "STOP REPLICA; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; SELECT @@hostname, @@read_only;"

kubectl -n "${NS}" patch cm mysql-topology --type merge -p "{\"data\":{\"primary-pod\":\"${NEW}\"}}"
kubectl -n "${NS}" label pod "${NEW}" mysql.role=primary --overwrite
if kubectl -n "${NS}" get pod "${OLD}" >/dev/null 2>&1; then
  kubectl -n "${NS}" label pod "${OLD}" mysql.role=replica --overwrite || true
  kubectl -n "${NS}" exec "${OLD}" -c mysql -- \
    mysql --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
    -uroot -p"${ROOT_PW}" -e "
      STOP REPLICA;
      SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;
      CHANGE REPLICATION SOURCE TO
        SOURCE_HOST='${NEW}.mysql-hl', SOURCE_PORT=3306,
        SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PW}',
        SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
      START REPLICA;
      SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" || true
fi

echo "▸ Endpoints"
kubectl -n "${NS}" get ep mysql -o wide
echo "✓ 当前主应为 ${NEW}（不会自动回切；下次故障才会再切）"
