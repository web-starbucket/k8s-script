#!/usr/bin/env bash
# 从当前主 dump 重建指定从库（解决 1236 binlog purged / GTID 空洞）
# 用法: bash rebuild-replica.sh mysql-1
set -euo pipefail
NS="${NS:-default}"
REPLICA="${1:?用法: $0 mysql-1}"
PRIMARY="$(kubectl -n "${NS}" get cm mysql-topology -o jsonpath='{.data.primary-pod}' | tr -d '[:space:]')"
ROOT_PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.root-password}' | base64 -d)"
REPL_PW="$(kubectl -n "${NS}" get secret mysql-auth -o jsonpath='{.data.replication-password}' | base64 -d)"
DUMP="/tmp/mysql-rebuild-${PRIMARY}-$$.sql"

[[ "${REPLICA}" != "${PRIMARY}" ]] || { echo "不能重建当前主 ${PRIMARY}"; exit 1; }

echo "▸ 主=${PRIMARY} → 重建从=${REPLICA}"
echo "▸ dump ${PRIMARY} ..."
kubectl -n "${NS}" exec "${PRIMARY}" -c mysql -- \
  mysqldump --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
  -uroot -p"${ROOT_PW}" \
  --all-databases --single-transaction --triggers --routines --events \
  --set-gtid-purged=ON > "${DUMP}"
ls -lh "${DUMP}"

echo "▸ 停复制、清空从库 GTID（避免与 dump 里 GTID_PURGED 重叠报 3546）..."
kubectl -n "${NS}" exec "${REPLICA}" -c mysql -- \
  mysql --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
  -uroot -p"${ROOT_PW}" -e "
    STOP REPLICA;
    SET GLOBAL super_read_only=OFF;
    SET GLOBAL read_only=OFF;
    RESET REPLICA ALL;
    RESET BINARY LOGS AND GTIDS;"

echo "▸ 导入 dump ..."
kubectl -n "${NS}" exec -i "${REPLICA}" -c mysql -- \
  mysql --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
  -uroot -p"${ROOT_PW}" < "${DUMP}"

echo "▸ 重新指向 ${PRIMARY}.mysql-hl ..."
kubectl -n "${NS}" exec "${REPLICA}" -c mysql -- \
  mysql --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock \
  -uroot -p"${ROOT_PW}" -e "
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='${PRIMARY}.mysql-hl',
      SOURCE_PORT=3306,
      SOURCE_USER='repl',
      SOURCE_PASSWORD='${REPL_PW}',
      SOURCE_AUTO_POSITION=1,
      GET_SOURCE_PUBLIC_KEY=1;
    START REPLICA;
    SET GLOBAL read_only=ON;
    SET GLOBAL super_read_only=ON;
    SELECT SERVICE_STATE AS io
      FROM performance_schema.replication_connection_status LIMIT 1;
    SELECT SERVICE_STATE AS applier
      FROM performance_schema.replication_applier_status LIMIT 1;"

rm -f "${DUMP}"
kubectl -n "${NS}" label pod "${REPLICA}" mysql.role=replica --overwrite >/dev/null 2>&1 || true
echo "✓ ${REPLICA} 已从 ${PRIMARY} 重建。IO/SQL 应为 ON"
