#!/usr/bin/env bash
# 从零安装 Gateway API(standard v1.5.1) + Envoy Gateway v1.8.2（Obsbot 镜像）
# 用法: bash install-eg-obsbot.sh
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
err()    { echo "  ${CR}❌${C0} ${CR}$*${C0}"; }
tip()    { echo "  ${CM}💡${C0} $*"; }
wait_()  { echo "  ${CY}⏳${C0} $*"; }
dim()    { echo "  ${CD}• $*${C0}"; }
kv()     { printf "  ${CD}%s:${C0} ${CB}%s${C0}\n" "$1" "$2"; }
done_()  { echo; echo "${CG}${CB}╔══════════════════════════════════════════════════════╗${C0}"; printf "${CG}${CB}║${C0}  ✅ %-48s ${CG}${CB}║${C0}\n" "$1"; echo "${CG}${CB}╚══════════════════════════════════════════════════════╝${C0}"; shift || true; for l in "$@"; do [[ -n "$l" ]] && echo "  ➜ $l"; done; echo; }
need()   { command -v "$1" >/dev/null || { err "缺少命令: $1"; exit 1; }; ok "已找到 $1"; }

# 严格串行：每次 kubectl 只提交 1 个资源；禁止多文档整包 apply（避免 HTTP/2 并发压垮 etcd）
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-180s}"
APPLY_RETRIES="${APPLY_RETRIES:-6}"
APPLY_SLEEP="${APPLY_SLEEP:-3}"

apply_ssa_one() {
  local file="$1"
  local label="${2:-$(basename "$file")}"
  local i=1
  local out="${TMPDIR}/apply-out.txt"
  local errf="${TMPDIR}/apply-err.txt"
  while true; do
    # 单文件、单次请求；不后台、不并行
    if kubectl apply --server-side --force-conflicts \
      --request-timeout="${KUBECTL_TIMEOUT}" \
      -f "${file}" >"${out}" 2>"${errf}"; then
      grep -E 'serverside-applied|configured|created|unchanged' "${out}" 2>/dev/null \
        | while read -r line; do dim "${line}"; done || true
      ok "${label}"
      # CRD：等 Established 再继续下一个，避免串行中仍触发大规模存储写
      if grep -qE '^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$' "${file}"; then
        local crd_name
        crd_name="$(awk '/^[[:space:]]*name:/{print $2; exit}' "${file}")"
        if [[ -n "${crd_name}" ]]; then
          wait_ "等待 CRD Established: ${crd_name}"
          kubectl wait --for=condition=Established "crd/${crd_name}" \
            --timeout="${KUBECTL_TIMEOUT}" >/dev/null 2>&1 || warn "Established 等待超时: ${crd_name}"
        fi
      fi
      return 0
    fi
    local reason
    reason="$(tr '\n' ' ' <"${errf}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
    # 空文档不应重试
    if echo "${reason}" | grep -qi 'no objects passed to apply'; then
      err "无效清单（无对象）: ${label}"
      dim "${reason}"
      return 1
    fi
    if (( i >= APPLY_RETRIES )); then
      err "应用失败（已重试 ${APPLY_RETRIES} 次）: ${label}"
      dim "${reason}"
      return 1
    fi
    if echo "${reason}" | grep -qiE 'timed out|timeout|GOAWAY|etcdserver'; then
      warn "超时，${i}/${APPLY_RETRIES} 重试: ${label}"
    else
      warn "失败，${i}/${APPLY_RETRIES} 重试: ${label}"
    fi
    dim "${reason}"
    sleep $(( i * APPLY_SLEEP + 2 ))
    i=$((i + 1))
  done
}

# 拆成单文档文件后，按文件名顺序严格串行 apply（一次只跑一个 kubectl）
split_and_apply() {
  local src="$1"
  local outdir="$2"
  local title="${3:-资源}"
  rm -rf "${outdir}"
  mkdir -p "${outdir}"
  local count
  count="$(python3 - "${src}" "${outdir}" <<'PY'
import re, sys, os
src, outdir = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# 去掉开头 BOM
text = text.lstrip("\ufeff")
parts = re.split(r"(?m)^---\s*$", text)
n = 0
skipped = 0

def sanitize(s: str) -> str:
    s = s.strip().strip("\"'")
    s = s.replace("/", "_").replace("\\", "_").replace(":", "_")
    s = re.sub(r'[^A-Za-z0-9._+-]+', "_", s)
    return s.strip("._-") or "unnamed"

for part in parts:
    body = part.strip()
    if not body:
        skipped += 1
        continue
    # 去掉纯注释/空行后仍须有 apiVersion + kind，否则 kubectl 报 no objects
    meaningful = "\n".join(
        ln for ln in body.splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    )
    if not meaningful:
        skipped += 1
        continue
    kind_m = re.search(r"(?m)^kind:\s*(\S+)\s*$", body)
    api_m = re.search(r"(?m)^apiVersion:\s*(\S+)\s*$", body)
    if not kind_m or not api_m:
        skipped += 1
        continue
    name_m = re.search(r'(?m)^  name:\s*["\']?([^"\'\s]+)["\']?\s*$', body)
    if not name_m:
        name_m = re.search(
            r'(?m)^metadata:\s*$[\s\S]*?^  name:\s*["\']?([^"\'\s]+)["\']?\s*$',
            body,
        )
    kind = sanitize(kind_m.group(1).lower())
    name = sanitize(name_m.group(1) if name_m else f"{n:03d}")
    path = os.path.join(outdir, f"{n:03d}-{kind}-{name}.yaml")
    open(path, "w", encoding="utf-8").write(body + "\n")
    n += 1
if n == 0:
    print("0", file=sys.stderr)
    sys.exit(1)
print(n)
PY
)" || { err "${title}: YAML 拆分后没有有效资源（检查下载是否完整）"; return 1; }
  info "${title}: ${count} 个资源 → 严格串行（1 次 kubectl / 1 个资源）"
  local idx=0
  local f
  while IFS= read -r f; do
    [[ -z "${f}" || ! -f "${f}" ]] && continue
    idx=$((idx + 1))
    info "串行 [${idx}/${count}] $(basename "${f}" .yaml)"
    apply_ssa_one "${f}" "$(basename "${f}" .yaml)" || return 1
    sleep "${APPLY_SLEEP}"
  done < <(find "${outdir}" -maxdepth 1 -type f -name '*.yaml' | sort)
}

wait_api() {
  wait_ "检查 API Server 是否可用..."
  local i=1
  while ! kubectl get --raw=/readyz >/dev/null 2>&1; do
    if (( i > 30 )); then
      err "API Server 长时间不可用，请检查 control-plane / etcd"
      exit 1
    fi
    wait_ "API 未就绪，等待… (${i}/30)"
    sleep 3
    i=$((i + 1))
  done
  ok "API Server Ready"
}

# 下载 GitHub Release 资源：打印完整 URL，多镜像回退，校验文件有效
# 用法: download_gh <目标文件> <github完整URL> [最小字节数]
download_gh() {
  local dest="$1"
  local gh_url="$2"
  local min_bytes="${3:-1024}"
  local proxies=(
    "${GH_PROXY}"
    "https://ghfast.top/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
    ""
  )
  local p url
  # 去重后的尝试列表
  local tried=()
  for p in "${proxies[@]}"; do
    if [[ -n "${p}" ]]; then
      # 保证代理以 / 结尾
      [[ "${p}" == */ ]] || p="${p}/"
      url="${p}${gh_url}"
    else
      url="${gh_url}"
    fi
    local skip=0
    for t in "${tried[@]:-}"; do
      [[ "${t}" == "${url}" ]] && skip=1 && break
    done
    (( skip )) && continue
    tried+=("${url}")
    dim "下载: ${url}"
    if curl -fL --connect-timeout 20 --retry 2 --retry-delay 2 \
      -o "${dest}.part" "${url}"; then
      local sz
      sz="$(wc -c <"${dest}.part" | tr -d ' ')"
      if (( sz < min_bytes )); then
        warn "文件过小 (${sz} bytes)，换源重试"
        rm -f "${dest}.part"
        continue
      fi
      if ! grep -qE '^apiVersion:' "${dest}.part" 2>/dev/null; then
        warn "内容不像 Kubernetes YAML，换源重试"
        rm -f "${dest}.part"
        continue
      fi
      mv -f "${dest}.part" "${dest}"
      ok "已下载 $(basename "${dest}") (${sz} bytes)"
      return 0
    fi
    warn "下载失败，换源..."
    rm -f "${dest}.part"
  done
  err "所有镜像均失败，目标 URL: ${gh_url}"
  tip "手动下载示例（变量必须有值）:"
  tip "  curl -fL -o /tmp/gateway-api.yaml \\"
  tip "    '${GH_PROXY}https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml'"
  return 1
}
# ─────────────────────────────────────────────────────

GH_PROXY="${GH_PROXY:-https://ghfast.top/}"
[[ "${GH_PROXY}" == */ ]] || GH_PROXY="${GH_PROXY}/"
OBSBOT_REG="${OBSBOT_REG:-registry.cn-chengdu.aliyuncs.com/obsbot}"
EG_VERSION="${EG_VERSION:-v1.8.2}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
NS="envoy-gateway-system"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

banner "Envoy Gateway 安装" "Gateway API ${GATEWAY_API_VERSION} · EG ${EG_VERSION} · Obsbot"

info "检查依赖..."
need kubectl
need curl
need python3
kv "GH_PROXY" "${GH_PROXY}"
kv "镜像仓库" "${OBSBOT_REG}"
kv "命名空间" "${NS}"
kv "kubectl 超时" "${KUBECTL_TIMEOUT}"
kv "应用模式" "严格串行（禁止整包并行）"

wait_api

step 1 6 "安装 Gateway API CRD（standard ${GATEWAY_API_VERSION}）"
download_gh "${TMPDIR}/gateway-api.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  100000
split_and_apply "${TMPDIR}/gateway-api.yaml" "${TMPDIR}/gwapi-crds" "Gateway API CRD"
ok "Gateway API CRD 已全部应用"

step 2 6 "下载 Envoy Gateway ${EG_VERSION}"
download_gh "${TMPDIR}/install.yaml" \
  "https://github.com/envoyproxy/gateway/releases/download/${EG_VERSION}/install.yaml" \
  10000
download_gh "${TMPDIR}/eg-crds.yaml" \
  "https://github.com/envoyproxy/gateway/releases/download/${EG_VERSION}/envoy-gateway-crds.yaml" \
  10000
ok "install.yaml / envoy-gateway-crds.yaml 已就绪"

step 3 6 "过滤 Gateway API CRD（避免 standard / experimental 冲突）"
KEEP_N="$(python3 - "${TMPDIR}/install.yaml" "${TMPDIR}/install-no-gwapi.yaml" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
parts = re.split(r"(?m)^---\s*$", text)
keep = []
for part in parts:
    body = part.strip()
    if not body:
        continue
    if re.search(r"(?m)^kind:\s*CustomResourceDefinition\s*$", body) and re.search(
        r"gateway\.networking(\.k8s\.io|\.x-k8s\.io)", body
    ):
        continue
    if re.search(r"(?m)^kind:\s*ValidatingAdmissionPolicy(Binding)?\s*$", body) and re.search(
        r"gateway\.networking", body
    ):
        continue
    keep.append(body)
open(dst, "w", encoding="utf-8").write("---\n" + "\n---\n".join(keep) + "\n")
print(len(keep))
PY
)"
ok "已过滤，保留 ${KEEP_N} 个文档"

step 4 6 "替换为 Obsbot 镜像"
sed \
  -e "s|docker.io/envoyproxy/gateway:${EG_VERSION}|${OBSBOT_REG}/gateway:${EG_VERSION}|g" \
  -e "s|envoyproxy/gateway:${EG_VERSION}|${OBSBOT_REG}/gateway:${EG_VERSION}|g" \
  -e "s|docker.io/envoyproxy/ratelimit:1e50889b|${OBSBOT_REG}/ratelimit:1e50889b|g" \
  -e "s|envoyproxy/ratelimit:1e50889b|${OBSBOT_REG}/ratelimit:1e50889b|g" \
  -e "s|docker.io/envoyproxy/ratelimit:fe26676d|${OBSBOT_REG}/ratelimit:fe26676d|g" \
  -e "s|envoyproxy/ratelimit:fe26676d|${OBSBOT_REG}/ratelimit:fe26676d|g" \
  "${TMPDIR}/install-no-gwapi.yaml" > "${TMPDIR}/install-obsbot.yaml"

while IFS= read -r img; do
  dim "${img}"
done < <(grep -E '^\s*image:' "${TMPDIR}/install-obsbot.yaml" | sort -u || true)
cp "${TMPDIR}/install-obsbot.yaml" "${WORKDIR}/install-obsbot-applied.yaml"
cp "${TMPDIR}/eg-crds.yaml" "${WORKDIR}/eg-crds.yaml"
ok "清单已写入 install-obsbot-applied.yaml"

step 5 6 "安装 EG CRD + 控制器（严格串行，无整包）"
split_and_apply "${TMPDIR}/eg-crds.yaml" "${TMPDIR}/eg-crds-split" "Envoy Gateway CRD"
split_and_apply "${TMPDIR}/install-obsbot.yaml" "${TMPDIR}/eg-install-split" "EG 控制器清单"
ok "控制器清单已全部串行应用"

step 6 6 "数据面 EnvoyProxy + GatewayClass（串行）"
split_and_apply "${WORKDIR}/eg-proxy-obsbot.yaml" "${TMPDIR}/eg-proxy-split" "EnvoyProxy / GatewayClass"
wait_ "等待 envoy-gateway Deployment Ready ..."
kubectl -n "${NS}" rollout status deployment/envoy-gateway --timeout=5m
ok "envoy-gateway 已就绪"
echo
kubectl -n "${NS}" get pods,svc,job -o wide

done_ "安装完成" \
  "创建 Gateway 后务必执行（避免单节点可访问）:" \
  "  bash ensure-envoy-nodeport.sh"

echo
echo "${CG}${CB}✨ 下一步：创建入口 Gateway${C0}"
echo "${CD}────────────────────────────────────────────────────────${C0}"
cat <<'EOF'
kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
YAML

bash ensure-envoy-nodeport.sh
kubectl get gateway eg -o wide
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg
EOF
echo "${CD}────────────────────────────────────────────────────────${C0}"
tip "关闭彩色输出可设置: NO_COLOR=1"
echo
