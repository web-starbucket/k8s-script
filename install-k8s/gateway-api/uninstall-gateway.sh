#!/usr/bin/env bash
# 一键彻底卸载 Gateway API + Envoy Gateway
# 用法:
#   bash uninstall-gateway.sh          # 交互确认
#   bash uninstall-gateway.sh --yes    # 跳过确认
set -euo pipefail

# ── 日志 ──────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C0=$'\033[0m' CB=$'\033[1m' CD=$'\033[2m'
  CR=$'\033[31m' CG=$'\033[32m' CY=$'\033[33m' CC=$'\033[36m'
else
  C0='' CB='' CD='' CR='' CG='' CY='' CC=''
fi
_ts() { date '+%H:%M:%S' 2>/dev/null || echo '--:--:--'; }
banner() { echo; echo "${CC}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CC}${CB}║${C0}  🗑️  %-47s ${CC}${CB}║${C0}\n" "$1"; [[ -n "${2:-}" ]] && printf "${CC}${CB}║${C0}  ${CD}%-48s${C0} ${CC}${CB}║${C0}\n" "$2"; echo "${CC}${CB}╚══════════════════════════════════════════════════════╝${C0}"; echo; }
step()   { echo; echo "${CC}${CB}⚙️  [$1/$2]${C0} ${CB}$3${C0}  ${CD}$(_ts)${C0}"; }
ok()     { echo "  ${CG}✅${C0} $*"; }
info()   { echo "  ${CC}ℹ️ ${C0} $*"; }
warn()   { echo "  ${CY}⚠️ ${C0}${CY}$*${C0}"; }
err()    { echo "  ${CR}❌${C0} ${CR}$*${C0}"; }
wait_()  { echo "  ${CY}⏳${C0} $*"; }
dim()    { echo "  ${CD}• $*${C0}"; }
done_()  { echo; echo "${CG}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CG}${CB}║${C0}  ✅ %-48s ${CG}${CB}║${C0}\n" "$1"; echo "${CG}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
fail_()  { echo; echo "${CR}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CR}${CB}║${C0}  ❌ %-48s ${CR}${CB}║${C0}\n" "$1"; echo "${CR}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
# ─────────────────────────────────────────────────────

YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    -h|--help)
      banner "卸载 Gateway API + Envoy Gateway" "bash uninstall-gateway.sh [--yes|-y]"
      info "将卸载 Envoy Gateway、全部 Gateway/HTTPRoute、Gateway API CRD"
      exit 0
      ;;
  esac
done

banner "卸载 Gateway API + Envoy Gateway" "将清理 CRD / NS / Webhook / RBAC"

if [[ "${YES}" != "1" ]]; then
  warn "将删除以下资源:"
  dim "全部 HTTPRoute / Gateway / GatewayClass 等业务资源"
  dim "命名空间 envoy-gateway-system（含 Envoy 数据面）"
  dim "Envoy Gateway / Gateway API 相关 CRD、Webhook、RBAC"
  echo
  read -r -p "  ⚠️  确认卸载？[y/N] " ans
  [[ "${ans}" =~ ^[yY]$ ]] || { info "已取消"; exit 0; }
fi

delete_all() {
  local resource="$1"
  kubectl delete "${resource}" --all -A --ignore-not-found=true --timeout=60s 2>/dev/null || true
}

step 1 8 "删除路由与策略资源"
for r in httproute grpcroute tcproute udproute tlsroute \
         referencegrant backendtlspolicy listenerset \
         backend backendtrafficpolicy clienttrafficpolicy \
         envoyproxy envoypatchpolicy envoyextensionpolicy \
         securitypolicy httproutefilter; do
  delete_all "${r}"
done
ok "路由与策略已清理"

step 2 8 "删除 Gateway / GatewayClass"
kubectl delete gateway --all -A --ignore-not-found=true --timeout=60s 2>/dev/null || true
kubectl delete gatewayclass --all --ignore-not-found=true --timeout=60s 2>/dev/null || true
ok "Gateway / GatewayClass 已删除"

step 3 8 "Helm release（若存在）"
if command -v helm >/dev/null 2>&1; then
  helm uninstall eg -n envoy-gateway-system 2>/dev/null || true
  helm uninstall envoy-gateway -n envoy-gateway-system 2>/dev/null || true
  ok "Helm release 已尝试卸载"
else
  dim "未安装 helm，跳过"
fi

step 4 8 "删除命名空间 envoy-gateway-system"
kubectl delete ns envoy-gateway-system --ignore-not-found=true --wait=false 2>/dev/null || true
if kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
  wait_ "等待命名空间删除（最长 120s）..."
  for i in $(seq 1 24); do
    kubectl get ns envoy-gateway-system >/dev/null 2>&1 || break
    sleep 5
  done
  if kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
    warn "命名空间未删完，清除 finalizers..."
    kubectl get ns envoy-gateway-system -o json \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); d["spec"]["finalizers"]=[]; print(json.dumps(d))' \
      | kubectl replace --raw "/api/v1/namespaces/envoy-gateway-system/finalize" -f - 2>/dev/null || true
    sleep 3
  fi
fi
if kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
  warn "命名空间仍存在，后续步骤继续"
else
  ok "命名空间已删除"
fi

step 5 8 "删除 Webhook / AdmissionPolicy"
kubectl delete mutatingwebhookconfiguration \
  envoy-gateway-topology-injector.envoy-gateway-system \
  --ignore-not-found=true 2>/dev/null || true
kubectl get mutatingwebhookconfiguration -o name 2>/dev/null \
  | grep -iE 'envoy-gateway|gateway-helm' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
kubectl get validatingwebhookconfiguration -o name 2>/dev/null \
  | grep -iE 'envoy-gateway|gateway-helm' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found=true 2>/dev/null || true
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found=true 2>/dev/null || true
kubectl get validatingadmissionpolicy -o name 2>/dev/null \
  | grep -iE 'gateway\.networking|envoy' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
kubectl get validatingadmissionpolicybinding -o name 2>/dev/null \
  | grep -iE 'gateway\.networking|envoy' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
ok "Webhook / AdmissionPolicy 已清理"

step 6 8 "删除 ClusterRole / ClusterRoleBinding"
kubectl get clusterrole -o name 2>/dev/null \
  | grep -iE 'envoy-gateway|gateway-helm|eg-gateway' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
kubectl get clusterrolebinding -o name 2>/dev/null \
  | grep -iE 'envoy-gateway|gateway-helm|eg-gateway' \
  | xargs -r kubectl delete --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrole \
  eg-gateway-helm-envoy-gateway-role \
  eg-gateway-helm-certgen:envoy-gateway-system \
  --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding \
  eg-gateway-helm-envoy-gateway-rolebinding \
  eg-gateway-helm-certgen:envoy-gateway-system \
  --ignore-not-found=true 2>/dev/null || true
ok "RBAC 已清理"

step 7 8 "删除 CRD（先去 finalizer，再删）"
remove_crd_finalizers() {
  local crd="$1"
  kubectl get "${crd}" -o name 2>/dev/null \
    | while read -r obj; do
        kubectl patch "${obj}" --type=json \
          -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      done
  kubectl patch "${crd}" --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
}

while read -r crd; do
  [[ -z "${crd}" ]] && continue
  dim "删除 ${crd}"
  remove_crd_finalizers "${crd}"
  kubectl delete "${crd}" --ignore-not-found=true --timeout=60s 2>/dev/null || true
done < <(kubectl get crd -o name 2>/dev/null | grep -E 'gateway\.(envoyproxy\.io|networking(\.k8s\.io|\.x-k8s\.io))' || true)
ok "CRD 删除流程完成"

step 8 8 "校验是否清理干净"
fail=0
if kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
  err "残留: namespace/envoy-gateway-system"
  fail=1
fi
left_crd="$(kubectl get crd -o name 2>/dev/null | grep -E 'gateway\.(envoyproxy\.io|networking(\.k8s\.io|\.x-k8s\.io))' || true)"
if [[ -n "${left_crd}" ]]; then
  err "残留 CRD:"
  echo "${left_crd}" | while read -r line; do dim "${line}"; done
  fail=1
fi
left_wh="$(kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name 2>/dev/null | grep -iE 'envoy-gateway|gateway-helm' || true)"
if [[ -n "${left_wh}" ]]; then
  err "残留 Webhook:"
  echo "${left_wh}" | while read -r line; do dim "${line}"; done
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  done_ "卸载完成，已清理干净" \
    "重新安装: bash install-eg.sh"
  exit 0
else
  fail_ "仍有残留" \
    "可再执行一次: bash $0 --yes"
  exit 1
fi
