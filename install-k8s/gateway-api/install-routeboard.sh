#!/usr/bin/env bash
# 安装 RouteBoard（需已把镜像推到 Obsbot，或临时改 YAML 用 ghcr）
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
tip()    { echo "  ${CM}💡${C0} $*"; }
wait_()  { echo "  ${CY}⏳${C0} $*"; }
dim()    { echo "  ${CD}• $*${C0}"; }
cmd_()   { echo "  ${CD}➜${C0} ${CC}$*${C0}"; }
done_()  { echo; echo "${CG}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CG}${CB}║${C0}  ✅ %-48s ${CG}${CB}║${C0}\n" "$1"; echo "${CG}${CB}╚══════════════════════════════════════════════════════╝${C0}"; echo; }
need()   { command -v "$1" >/dev/null || { echo "  ${CR}❌${C0} 缺少命令: $1"; exit 1; }; ok "已找到 $1"; }
# ─────────────────────────────────────────────────────

DIR="$(cd "$(dirname "$0")" && pwd)"

banner "安装 RouteBoard" "Gateway API 路由看板"

need kubectl

step 1 2 "应用 routeboard.yaml"
kubectl apply -f "${DIR}/routeboard.yaml"
ok "清单已应用"

step 2 2 "等待 Deployment Ready"
wait_ "rollout status deploy/routeboard ..."
kubectl -n routeboard rollout status deploy/routeboard --timeout=3m
ok "RouteBoard 已就绪"
echo
kubectl -n routeboard get pods,svc -o wide

done_ "RouteBoard 安装完成"
echo "${CG}${CB}✨ 访问入口${C0}"
echo "${CD}────────────────────────────────────────────────────────${C0}"
cmd_ "NodePort:  http://任意节点IP:32080/"
cmd_ "例:        http://172.16.10.117:32080/"
cmd_ "Gateway:   http://GatewayIP:32030/routeboard   (若 HTTPRoute 已挂上)"
echo "${CD}────────────────────────────────────────────────────────${C0}"
tip "给业务 HTTPRoute 加展示注解（可选）:"
dim 'routeboard.io/title: "Nginx"'
dim 'routeboard.io/url: "http://172.16.10.117:32030/"'
dim 'routeboard.io/group: "Demo"'
echo
