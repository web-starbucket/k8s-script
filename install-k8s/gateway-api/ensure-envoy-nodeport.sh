#!/usr/bin/env bash
# 确保 Gateway 数据面 Service：NodePort + externalTrafficPolicy=Cluster
# 避免「只有某一个节点 IP:NodePort 能访问」
# 用法（创建 Gateway 之后）:
#   bash ensure-envoy-nodeport.sh
#   bash ensure-envoy-nodeport.sh eg default
set -euo pipefail

# ── 日志 ──────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C0=$'\033[0m' CB=$'\033[1m' CD=$'\033[2m'
  CR=$'\033[31m' CG=$'\033[32m' CY=$'\033[33m' CC=$'\033[36m' CM=$'\033[35m'
else
  C0='' CB='' CD='' CR='' CG='' CY='' CC='' CM=''
fi
_ts() { date '+%H:%M:%S' 2>/dev/null || echo '--:--:--'; }
banner() { echo; echo "${CC}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CC}${CB}║${C0}  🚀 %-48s ${CC}${CB}║${C0}\n" "$1"; [[ -n "${2:-}" ]] && printf "${CC}${CB}║${C0}  ${CD}%-48s${C0} ${CC}${CB}║${C0}\n" "$2"; echo "${CC}${CB}╚══════════════════════════════════════════════════════╝${C0}"; echo; }
step()   { echo; echo "${CC}${CB}⚙️  [$1/$2]${C0} ${CB}$3${C0}  ${CD}$(_ts)${C0}"; }
ok()     { echo "  ${CG}✅${C0} $*"; }
warn()   { echo "  ${CY}⚠️ ${C0}${CY}$*${C0}"; }
wait_()  { echo "  ${CY}⏳${C0} $*"; }
search() { echo "  ${CC}🔍${C0} $*"; }
dim()    { echo "  ${CD}• $*${C0}"; }
kv()     { printf "  ${CD}%s:${C0} ${CB}%s${C0}\n" "$1" "$2"; }
done_()  { echo; echo "${CG}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CG}${CB}║${C0}  ✅ %-48s ${CG}${CB}║${C0}\n" "$1"; echo "${CG}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
fail_()  { echo; echo "${CR}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CR}${CB}║${C0}  ❌ %-48s ${CR}${CB}║${C0}\n" "$1"; echo "${CR}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
need()   { command -v "$1" >/dev/null || { echo "  ${CR}❌${C0} 缺少命令: $1"; exit 1; }; ok "已找到 $1"; }
# ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GW_NAME="${1:-eg}"
GW_NS="${2:-default}"
SYS_NS="envoy-gateway-system"

banner "纠正数据面 NodePort" "Gateway ${GW_NS}/${GW_NAME} → Cluster 策略"

need kubectl

step 1 3 "应用 EnvoyProxy（固化 NodePort + Cluster）"
# 与安装脚本一致用 server-side，避免 last-applied-configuration 警告
kubectl apply --server-side --force-conflicts -f "${SCRIPT_DIR}/eg-proxy.yaml"
ok "eg-proxy.yaml 已应用"

step 2 3 "查找数据面 Service"
search "label: owning-gateway=${GW_NS}/${GW_NAME}"
svc=""
for i in $(seq 1 30); do
  svc="$(kubectl -n "${SYS_NS}" get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    break
  fi
  wait_ "等待 Service 出现… (${i}/30)"
  sleep 2
done

if [[ -z "${svc}" ]]; then
  fail_ "未找到数据面 Service" \
    "请先创建 Gateway，例如:" \
    "  kubectl apply -f gateway.yaml"
  exit 1
fi
ok "找到 Service: ${SYS_NS}/${svc}"

step 3 3 "Patch → NodePort + externalTrafficPolicy=Cluster"
kubectl -n "${SYS_NS}" patch svc "${svc}" --type merge -p '{
  "spec": {
    "type": "NodePort",
    "externalTrafficPolicy": "Cluster"
  }
}'
ok "Service 已更新"

echo
kubectl -n "${SYS_NS}" get svc "${svc}" -o wide
TYPE="$(kubectl -n "${SYS_NS}" get svc "${svc}" -o jsonpath='{.spec.type}')"
POLICY="$(kubectl -n "${SYS_NS}" get svc "${svc}" -o jsonpath='{.spec.externalTrafficPolicy}')"
NODE_PORT="$(kubectl -n "${SYS_NS}" get svc "${svc}" -o jsonpath='{.spec.ports[0].nodePort}')"

kv "type" "${TYPE}"
kv "externalTrafficPolicy" "${POLICY}"
kv "nodePort" "${NODE_PORT}"

if [[ "${TYPE}" != "NodePort" || "${POLICY}" != "Cluster" ]]; then
  warn "配置未完全生效，请手动检查 Service"
fi

done_ "配置完成" \
  "任意节点访问: http://<节点IP>:${NODE_PORT}/"

echo "${CG}${CB}✨ 多节点自检${C0}"
echo "${CD}────────────────────────────────────────────────────────${C0}"
cat <<EOF
for ip in \$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  curl -s -o /dev/null -w "%{http_code} \$ip\\n" --connect-timeout 2 "http://\$ip:${NODE_PORT}/" || echo "fail \$ip"
done
EOF
echo "${CD}────────────────────────────────────────────────────────${C0}"
echo
