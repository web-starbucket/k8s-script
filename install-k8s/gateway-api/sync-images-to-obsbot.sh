#!/usr/bin/env bash
# 将 Envoy Gateway v1.8.2（适配 K8s 1.33）相关镜像同步到 Obsbot 成都仓库
# 目标路径: registry.cn-chengdu.aliyuncs.com/obsbot/<name>:<tag>（无 envoyproxy/ 前缀）
# 用法: bash sync-images-to-obsbot.sh
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
info()   { echo "  ${CC}ℹ️ ${C0} $*"; }
warn()   { echo "  ${CY}⚠️ ${C0}${CY}$*${C0}"; }
tip()    { echo "  ${CM}💡${C0} $*"; }
dim()    { echo "  ${CD}• $*${C0}"; }
kv()     { printf "  ${CD}%s:${C0} ${CB}%s${C0}\n" "$1" "$2"; }
cmd_()   { echo "  ${CD}➜${C0} ${CC}$*${C0}"; }
done_()  { echo; echo "${CG}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CG}${CB}║${C0}  ✅ %-48s ${CG}${CB}║${C0}\n" "$1"; echo "${CG}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
need()   { command -v "$1" >/dev/null || { echo "  ${CR}❌${C0} 缺少命令: $1"; exit 1; }; ok "已找到 $1"; }
# ─────────────────────────────────────────────────────

OBSBOT_REG="registry.cn-chengdu.aliyuncs.com/obsbot"
DAO_MIRROR="docker.m.daocloud.io"

IMAGES=(
  "gateway:v1.8.2"
  "envoy:distroless-v1.38.0"
  "ratelimit:1e50889b"
  "ratelimit:fe26676d"
)

banner "同步镜像到 Obsbot" "${OBSBOT_REG}/<name>:<tag>"

need docker
tip "请先执行: docker login registry.cn-chengdu.aliyuncs.com"
kv "镜像数量" "${#IMAGES[@]}"
kv "优先镜像源" "${DAO_MIRROR}"
echo

idx=0
total="${#IMAGES[@]}"
for name_tag in "${IMAGES[@]}"; do
  idx=$((idx + 1))
  dest="${OBSBOT_REG}/${name_tag}"
  mirror="${DAO_MIRROR}/envoyproxy/${name_tag}"
  official="docker.io/envoyproxy/${name_tag}"

  step "${idx}" "${total}" "envoyproxy/${name_tag}"
  kv "pull" "${mirror}"
  dim "fallback: ${official}"
  kv "push" "${dest}"

  if docker pull "${mirror}"; then
    docker tag "${mirror}" "${dest}"
    ok "已从 DaoCloud 拉取并打标签"
  else
    warn "DaoCloud 拉取失败，改用官方源"
    docker pull "${official}"
    docker tag "${official}" "${dest}"
    ok "已从官方源拉取并打标签"
  fi

  docker push "${dest}"
  ok "已推送 ${dest}"
done

done_ "同步完成"
echo "${CG}${CB}✨ Obsbot 镜像列表${C0}"
echo "${CD}────────────────────────────────────────────────────────${C0}"
for img in "${IMAGES[@]}"; do
  dim "${OBSBOT_REG}/${img}"
done
echo "${CD}────────────────────────────────────────────────────────${C0}"
info "CRD（非镜像）:"
cmd_ "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml"
info "Helm chart:"
cmd_ "oci://docker.io/envoyproxy/gateway-helm --version v1.8.2"
echo
