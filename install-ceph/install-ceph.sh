#!/usr/bin/env bash
# 用法: bash install-ceph.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEPH_NODES_FILE="${CEPH_NODES_FILE:-${SCRIPT_DIR}/ceph-nodes.conf}"
REMOTE_DIR="/opt/service/ceph"

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo; echo -e "${CYAN}${BOLD}▸${NC} ${BOLD}$*${NC}"; }
item() { echo -e "  ${DIM}·${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*" >&2; }
skip() { echo -e "  ${DIM}–${NC} $*"; }
log()  { item "$@"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
sum()  { echo -e "${DIM}──${NC} $*"; echo; }

CEPH_RELEASE_DEFAULT="tentacle"
RBD_POOL_DEFAULT="kubernetes"
RBD_PG_NUM_DEFAULT="32"

_CONF_CEPH_RELEASE=""
_CONF_CEPH_APT_MIRROR=""
_CONF_IMAGE_MIRROR=""
_CONF_CEPH_IMAGE=""
_CONF_RBD_POOL=""
_CONF_RBD_PG_NUM=""
_CONF_CLUSTER_NETWORK=""
_CONF_DASHBOARD_PASSWORD=""
_CONF_OSD_ALLOW_ALL=""
_CONF_SKIP_MONITORING_STACK=""

is_conf_kv_line() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

load_conf_kv() {
  local f="$1" line key val
  [[ -f "${f}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//$'\r'/}"
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    is_conf_kv_line "${line}" || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    case "${key}" in
      CEPH_RELEASE) _CONF_CEPH_RELEASE="${val}" ;;
      CEPH_APT_MIRROR) _CONF_CEPH_APT_MIRROR="${val}" ;;
      IMAGE_MIRROR) _CONF_IMAGE_MIRROR="${val}" ;;
      CEPH_IMAGE) _CONF_CEPH_IMAGE="${val}" ;;
      RBD_POOL) _CONF_RBD_POOL="${val}" ;;
      RBD_PG_NUM) _CONF_RBD_PG_NUM="${val}" ;;
      CLUSTER_NETWORK) _CONF_CLUSTER_NETWORK="${val}" ;;
      DASHBOARD_PASSWORD) _CONF_DASHBOARD_PASSWORD="${val}" ;;
      OSD_ALLOW_ALL) _CONF_OSD_ALLOW_ALL="${val}" ;;
      SKIP_MONITORING_STACK) _CONF_SKIP_MONITORING_STACK="${val}" ;;
    esac
  done <"${f}"
}

[[ -f "${CEPH_NODES_FILE}" ]] || err "缺少配置 ${CEPH_NODES_FILE}"
load_conf_kv "${CEPH_NODES_FILE}"

CEPH_RELEASE="${CEPH_RELEASE:-${_CONF_CEPH_RELEASE:-${CEPH_RELEASE_DEFAULT}}}"
CEPH_RELEASE="$(printf '%s' "${CEPH_RELEASE}" | tr 'A-Z' 'a-z')"
CEPH_APT_MIRROR="${CEPH_APT_MIRROR:-${_CONF_CEPH_APT_MIRROR:-}}"
IMAGE_MIRROR="${IMAGE_MIRROR:-${_CONF_IMAGE_MIRROR:-}}"
IMAGE_MIRROR="${IMAGE_MIRROR%/}"
CEPH_IMAGE="${CEPH_IMAGE:-${_CONF_CEPH_IMAGE:-}}"
RBD_POOL="${RBD_POOL:-${_CONF_RBD_POOL:-${RBD_POOL_DEFAULT}}}"
RBD_PG_NUM="${RBD_PG_NUM:-${_CONF_RBD_PG_NUM:-${RBD_PG_NUM_DEFAULT}}}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-${_CONF_CLUSTER_NETWORK:-}}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-${_CONF_DASHBOARD_PASSWORD:-}}"
OSD_ALLOW_ALL="${OSD_ALLOW_ALL:-${_CONF_OSD_ALLOW_ALL:-0}}"
SKIP_MONITORING_STACK="${SKIP_MONITORING_STACK:-${_CONF_SKIP_MONITORING_STACK:-0}}"

if [[ -n "${CEPH_APT_MIRROR}" && "${CEPH_APT_MIRROR}" != http://* && "${CEPH_APT_MIRROR}" != https://* ]]; then
  if [[ -z "${IMAGE_MIRROR}" ]]; then
    IMAGE_MIRROR="${CEPH_APT_MIRROR%/}"
    warn "CEPH_APT_MIRROR 不是 http(s)，已当作 IMAGE_MIRROR=${IMAGE_MIRROR}"
  else
    warn "CEPH_APT_MIRROR 无效，已忽略（容器走 IMAGE_MIRROR）"
  fi
  CEPH_APT_MIRROR=""
fi

need_root() {
  [[ $EUID -eq 0 ]] || err "请用 root：sudo bash $0 $*"
}

mirror_image() {
  local img="$1"
  if [[ -z "${IMAGE_MIRROR}" ]]; then
    printf '%s' "${img}"
    return
  fi
  case "${img}" in
    "${IMAGE_MIRROR}/"*) printf '%s' "${img}" ;;
    *) printf '%s/%s' "${IMAGE_MIRROR}" "${img}" ;;
  esac
}

official_ceph_image() {
  case "${CEPH_RELEASE}" in
    tentacle) printf '%s' "quay.io/ceph/ceph:v20" ;;
    squid)    printf '%s' "quay.io/ceph/ceph:v19" ;;
    reef)     printf '%s' "quay.io/ceph/ceph:v18" ;;
    *)        printf '%s' "quay.io/ceph/ceph:v20" ;;
  esac
}

default_ceph_image() {
  if [[ -n "${CEPH_IMAGE}" ]]; then
    printf '%s' "${CEPH_IMAGE}"
    return
  fi
  mirror_image "$(official_ceph_image)"
}

list_official_monitor_images() {
  case "${CEPH_RELEASE}" in
    squid)
      echo "quay.io/prometheus/prometheus:v2.51.0"
      echo "quay.io/prometheus/alertmanager:v0.27.0"
      echo "quay.io/prometheus/node-exporter:v1.7.0"
      echo "quay.io/ceph/ceph-grafana:9.4.7"
      ;;
    reef)
      echo "quay.io/prometheus/prometheus:v2.43.0"
      echo "quay.io/prometheus/alertmanager:v0.25.0"
      echo "quay.io/prometheus/node-exporter:v1.5.0"
      echo "quay.io/ceph/ceph-grafana:9.4.7"
      ;;
    *)
      echo "quay.io/prometheus/prometheus:v3.6.0"
      echo "quay.io/prometheus/alertmanager:v0.28.1"
      echo "quay.io/prometheus/node-exporter:v1.9.1"
      echo "quay.io/ceph/grafana:12.3.1"
      ;;
  esac
}

list_deploy_images() {
  default_ceph_image
  echo
  if [[ "${SKIP_MONITORING_STACK}" != "1" ]]; then
    local img
    while IFS= read -r img; do
      [[ -n "${img}" ]] || continue
      mirror_image "${img}"
      echo
    done < <(list_official_monitor_images)
  fi
}

image_pull_status() {
  local img="$1"
  if command -v docker >/dev/null 2>&1 && docker image inspect "${img}" >/dev/null 2>&1; then
    echo "已有"
  else
    echo "未拉取"
  fi
}

print_image_list() {
  local img st
  step "镜像  ${CEPH_RELEASE}"
  [[ -n "${IMAGE_MIRROR}" ]] && item "仓库  ${IMAGE_MIRROR}" || item "仓库  quay.io（官方）"
  [[ -n "${CEPH_IMAGE}" ]] && item "主镜像覆盖  ${CEPH_IMAGE}"
  while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    st="$(image_pull_status "${img}")"
    if [[ "${st}" == "已有" ]]; then
      ok "${img}"
    else
      item "${img}"
    fi
  done < <(list_deploy_images)
}

cmd_images() {
  print_image_list
  echo
  list_deploy_images
}

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
)

is_local_ip() {
  local ip="$1"
  hostname -I 2>/dev/null | grep -qw "${ip}"
}

list_node_lines() {
  awk '
    BEGIN { FS="|" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/ { next }
    {
      gsub(/\r/, "")
      if (NF >= 5) print
    }
  ' "${CEPH_NODES_FILE}"
}

list_ssh_nodes() { list_node_lines; }

csi_monitors_yaml() {
  list_node_lines | awk -F'|' '
    {
      ip = $1
      gsub(/[[:space:]]/, "", ip)
      if (ip == "") next
      n++
      ips[n] = ip
    }
    END {
      for (i = 1; i <= n; i++) {
        printf "          \"%s:6789\"", ips[i]
        if (i < n) print ","
        else print ""
      }
    }
  '
}

write_csi_secret_yaml() {
  local dest="$1" key="$2"
  local mons
  mons="$(csi_monitors_yaml)"
  [[ -n "${mons}" ]] || err "ceph-nodes.conf 没有节点 IP，无法生成 CSI monitors"
  mkdir -p "$(dirname "${dest}")"
  cat >"${dest}" <<EOF
# monitors 来自 ceph-nodes.conf；密钥用 export-rbd
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: ceph-csi
stringData:
  userID: kubernetes
  userKey: "${key}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: ceph-csi
data:
  config.json: |-
    [
      {
        "clusterID": "ceph",
        "monitors": [
${mons}
        ]
      }
    ]
EOF
}

sync_csi_example_from_conf() {
  write_csi_secret_yaml \
    "${SCRIPT_DIR}/csi/secret.yaml.example" \
    "REPLACE_WITH_ceph_auth_get-key_client.kubernetes"
  ok "csi/secret.yaml.example  monitors 已按 conf 更新"
}

cmd_csi_example() {
  step "csi-example"
  sync_csi_example_from_conf
  awk '/"monitors"/, /\]/' "${SCRIPT_DIR}/csi/secret.yaml.example" || true
}

ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  item "安装 sshpass"
  apt-get update -y >/dev/null
  apt-get install -y sshpass
}

remote_ssh() {
  local user="$1" ip="$2" pass="$3" cmd="$4"
  if is_local_ip "${ip}"; then
    bash -c "${cmd}"
    return $?
  fi
  if ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "${user}@${ip}" "true" 2>/dev/null; then
    ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=30 "${user}@${ip}" "${cmd}"
    return $?
  fi
  [[ -n "${pass}" ]] || return 1
  SSHPASS="${pass}" sshpass -e ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=30 "${user}@${ip}" "${cmd}"
}

remote_scp() {
  local user="$1" ip="$2" pass="$3" src="$4" dst="$5"
  if is_local_ip "${ip}"; then
    mkdir -p "$(dirname "${dst}")"
    cp -f "${src}" "${dst}"
    return $?
  fi
  if ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "${user}@${ip}" "true" 2>/dev/null; then
    scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=30 "${src}" "${user}@${ip}:${dst}" </dev/null
    return $?
  fi
  [[ -n "${pass}" ]] || return 1
  SSHPASS="${pass}" sshpass -e scp "${SSH_OPTS[@]}" -o ConnectTimeout=30 "${src}" "${user}@${ip}:${dst}" </dev/null
}

placeholder_pass() {
  local p="$1"
  [[ "${p}" == "ChangeMe" || "${p}" == "请改成真实密码" ]]
}

bootstrap_ip() {
  list_node_lines | awk -F'|' 'tolower($3)=="bootstrap" {print $1; exit}'
}

bootstrap_host() {
  list_node_lines | awk -F'|' 'tolower($3)=="bootstrap" {print $2; exit}'
}

node_count() {
  list_node_lines | grep -c . || true
}

build_hosts_block() {
  echo "# ceph-cluster BEGIN"
  list_node_lines | awk -F'|' '{printf "%s\t%s\n", $1, $2}'
  echo "# ceph-cluster END"
}

apply_hosts() {
  local tmp block
  tmp="$(mktemp)"
  block="$(build_hosts_block)"
  awk '
    BEGIN { skip=0 }
    /^# ceph-cluster BEGIN$/ { skip=1; next }
    /^# ceph-cluster END$/ { skip=0; next }
    skip==0 { print }
  ' /etc/hosts >"${tmp}"
  printf '\n%s\n' "${block}" >>"${tmp}"
  cat "${tmp}" >/etc/hosts
  rm -f "${tmp}"
}

maybe_set_hostname() {
  local ip host
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host="$(list_node_lines | awk -F'|' -v w="${ip}" '$1==w {print $2; exit}')"
  if [[ -z "${host}" ]]; then
    local a
    for a in $(hostname -I 2>/dev/null); do
      host="$(list_node_lines | awk -F'|' -v w="${a}" '$1==w {print $2; exit}')"
      [[ -n "${host}" ]] && break
    done
  fi
  [[ -n "${host}" ]] || return 0
  if [[ "$(hostname)" != "${host}" ]]; then
    item "主机名 → ${host}"
    hostnamectl set-hostname "${host}"
  fi
}

install_ceph_repo() {
  local codename keyring listf mirror
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  keyring="/etc/apt/keyrings/ceph.gpg"
  listf="/etc/apt/sources.list.d/ceph.list"
  mkdir -p /etc/apt/keyrings
  if [[ ! -f "${keyring}" ]]; then
    curl -fsSL https://download.ceph.com/keys/release.asc | gpg --dearmor -o "${keyring}"
  fi
  if [[ -n "${CEPH_APT_MIRROR}" ]]; then
    mirror="${CEPH_APT_MIRROR%/}"
  else
    mirror="https://download.ceph.com/debian-${CEPH_RELEASE}"
  fi
  echo "deb [signed-by=${keyring}] ${mirror}/ ${codename} main" >"${listf}"
  apt-get update -y
}

do_prepare() {
  need_root prepare
  export DEBIAN_FRONTEND=noninteractive
  step "prepare  $(hostname)"
  maybe_set_hostname
  apply_hosts
  item "安装 docker / chrony / cephadm"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lvm2 chrony docker.io

  systemctl enable --now chrony
  systemctl enable --now docker

  install_ceph_repo
  apt-get install -y cephadm ceph-common

  local img
  img="$(default_ceph_image)"
  item "拉取 ${img}"
  docker pull "${img}" || warn "预拉失败，bootstrap 时再试"

  timedatectl set-ntp true || true
  ok "$(hostname)  $(hostname -I | awk '{print $1}')"
}

cmd_prepare() { do_prepare; }

cmd_hosts() {
  need_root hosts
  step "hosts"
  maybe_set_hostname
  apply_hosts
  ok "/etc/hosts 已写入 Ceph 节点"
}

sync_install_to_node() {
  local user="$1" ip="$2" pass="$3"
  remote_ssh "${user}" "${ip}" "${pass}" "mkdir -p ${REMOTE_DIR}" || return 1
  remote_scp "${user}" "${ip}" "${pass}" "${SCRIPT_DIR}/install-ceph.sh" "${REMOTE_DIR}/install-ceph.sh" || return 1
  remote_scp "${user}" "${ip}" "${pass}" "${CEPH_NODES_FILE}" "${REMOTE_DIR}/ceph-nodes.conf" || return 1
  remote_ssh "${user}" "${ip}" "${pass}" "chmod +x ${REMOTE_DIR}/install-ceph.sh"
}

for_each_node() {
  local fn="$1"
  local ip host role user pass disks n_ok=0 n_fail=0 n_skip=0
  while IFS='|' read -r ip host role user pass disks || [[ -n "${ip:-}" ]]; do
    [[ -n "${ip}" ]] || continue
    pass="$(printf '%s' "${pass:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    disks="$(printf '%s' "${disks:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    if "${fn}" "${ip}" "${host}" "${role}" "${user}" "${pass}" "${disks}"; then
      n_ok=$((n_ok + 1))
    else
      n_fail=$((n_fail + 1))
    fi
  done < <(list_ssh_nodes)
  sum "成功 ${n_ok}    失败 ${n_fail}"
  [[ "${n_fail}" -eq 0 ]]
}

_remote_cmd() {
  local cmd="$1" ip="$2" host="$3" role="$4" user="$5" pass="$6"
  item "${host}  ${ip}  [${role}]"
  if is_local_ip "${ip}"; then
    bash "${SCRIPT_DIR}/install-ceph.sh" "${cmd}"
    return $?
  fi
  if [[ -z "${pass}" ]] && ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "true" 2>/dev/null; then
    fail "${ip}  无法 SSH，先跑 ssh-keys"
    return 1
  fi
  if placeholder_pass "${pass}"; then
    fail "${ip}  请改 conf 里的真实密码"
    return 1
  fi
  sync_install_to_node "${user}" "${ip}" "${pass}" || return 1
  remote_ssh "${user}" "${ip}" "${pass}" "cd ${REMOTE_DIR} && bash install-ceph.sh ${cmd}"
}

cmd_prepare_all() {
  need_root prepare-all
  ensure_sshpass
  step "prepare-all"
  print_image_list
  _wrap_prepare() { _remote_cmd prepare "$@"; }
  for_each_node _wrap_prepare
}

cmd_hosts_all() {
  need_root hosts-all
  ensure_sshpass
  step "hosts-all"
  _wrap_hosts() { _remote_cmd hosts "$@"; }
  for_each_node _wrap_hosts
  sync_csi_example_from_conf
}

cmd_ssh_keys() {
  need_root ssh-keys
  ensure_sshpass
  step "ssh-keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f /root/.ssh/id_rsa ]]; then
    item "生成本机 RSA 密钥"
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -C "ceph-root@$(hostname)"
  fi
  chmod 600 /root/.ssh/id_rsa
  chmod 644 /root/.ssh/id_rsa.pub
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  local pub
  pub="$(cat /root/.ssh/id_rsa.pub)"
  grep -qxF "${pub}" /root/.ssh/authorized_keys || echo "${pub}" >>/root/.ssh/authorized_keys

  local count ip host role user pass errf n_ok=0 n_fail=0
  count="$(node_count)"
  [[ "${count}" -ge 1 ]] || err "节点表为空"
  errf="$(mktemp)"
  item "分发公钥  ${count} 台"
  while IFS='|' read -r ip host role user pass disks || [[ -n "${ip:-}" ]]; do
    [[ -n "${ip}" ]] || continue
    pass="$(printf '%s' "${pass:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    if is_local_ip "${ip}"; then
      skip "本机  ${host}"
      continue
    fi
    if [[ -z "${pass}" ]] || placeholder_pass "${pass}"; then
      fail "${host}  ${ip}  未填真实密码"
      n_fail=$((n_fail + 1))
      continue
    fi
    : >"${errf}"
    if SSHPASS="${pass}" sshpass -e ssh-copy-id -i /root/.ssh/id_rsa.pub \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${user}@${ip}" </dev/null >/dev/null 2>"${errf}"; then
      ok "${host}  ${ip}"
      n_ok=$((n_ok + 1))
    else
      fail "${host}  ${ip}  $(tr '\n' ' ' <"${errf}" | cut -c1-80)"
      n_fail=$((n_fail + 1))
    fi
    SSHPASS="${pass}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
      "${user}@${ip}" \
      'mkdir -p /root/.ssh; chmod 700 /root/.ssh; test -f /root/.ssh/id_rsa || ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa' \
      </dev/null >/dev/null 2>&1 || true
  done < <(list_ssh_nodes)
  rm -f "${errf}"

  item "节点互免密"
  local tmp_bundle merge_sh
  tmp_bundle="$(mktemp)"
  merge_sh="$(mktemp)"
  {
    echo "# ceph cluster keys"
    cat /root/.ssh/id_rsa.pub
  } >"${tmp_bundle}"
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    is_local_ip "${ip}" && continue
    ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "cat /root/.ssh/id_rsa.pub" >>"${tmp_bundle}" 2>/dev/null || true
  done < <(list_ssh_nodes)
  sort -u "${tmp_bundle}" -o "${tmp_bundle}"
  while IFS= read -r line; do
    [[ "${line}" =~ ^# ]] && continue
    [[ -z "${line}" ]] && continue
    grep -qxF "${line}" /root/.ssh/authorized_keys || echo "${line}" >>/root/.ssh/authorized_keys
  done <"${tmp_bundle}"

  cat >"${merge_sh}" <<'EOS'
#!/bin/bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  grep -qxF "$line" /root/.ssh/authorized_keys || echo "$line" >> /root/.ssh/authorized_keys
done < /tmp/ceph_authorized_bundle
rm -f /tmp/ceph_authorized_bundle
EOS
  chmod +x "${merge_sh}"
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    is_local_ip "${ip}" && continue
    if scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 \
      "${tmp_bundle}" "${user}@${ip}:/tmp/ceph_authorized_bundle" </dev/null 2>/dev/null \
      && scp "${SSH_OPTS[@]}" -o BatchMode=yes "${merge_sh}" "${user}@${ip}:/tmp/ceph_merge_keys.sh" </dev/null 2>/dev/null \
      && ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "${user}@${ip}" "bash /tmp/ceph_merge_keys.sh; rm -f /tmp/ceph_merge_keys.sh"; then
      ok "互通  ${host}"
    else
      fail "互通  ${host}"
    fi
  done < <(list_ssh_nodes)
  rm -f "${tmp_bundle}" "${merge_sh}"
  sum "公钥 成功 ${n_ok}    失败 ${n_fail}"
}

run_ceph() {
  if command -v ceph >/dev/null 2>&1 && [[ -f /etc/ceph/ceph.conf ]]; then
    ceph "$@"
  else
    cephadm shell -- ceph "$@"
  fi
}

cmd_bootstrap() {
  need_root bootstrap
  local bip bhost
  bip="$(bootstrap_ip)"
  bhost="$(bootstrap_host)"
  [[ -n "${bip}" ]] || err "节点表需要一行 role=bootstrap"
  is_local_ip "${bip}" || err "请在 ${bhost} (${bip}) 上执行 bootstrap"

  step "bootstrap  ${bhost}  ${bip}"
  print_image_list

  if [[ -f /etc/ceph/ceph.conf ]] && run_ceph -s >/dev/null 2>&1; then
    ok "集群已存在，跳过"
    run_ceph -s
    return 0
  fi

  [[ "$(node_count)" -ge 3 ]] || warn "节点不足 3 台，三副本 / MON 法定人数不完整"

  local ceph_img cfg_tmp=""
  ceph_img="$(default_ceph_image)"
  local args=(bootstrap --mon-ip "${bip}" --ssh-user root --allow-fqdn-hostname --image "${ceph_img}")
  [[ -n "${CLUSTER_NETWORK}" ]] && args+=(--cluster-network "${CLUSTER_NETWORK}")
  if [[ -n "${DASHBOARD_PASSWORD}" ]]; then
    args+=(--initial-dashboard-password "${DASHBOARD_PASSWORD}" --dashboard-password-noupdate)
  fi
  if [[ "${SKIP_MONITORING_STACK}" == "1" ]]; then
    args+=(--skip-monitoring-stack)
  elif [[ -n "${IMAGE_MIRROR}" ]]; then
    cfg_tmp="$(mktemp)"
    {
      echo "# generated by install-ceph.sh IMAGE_MIRROR=${IMAGE_MIRROR}"
      echo "[mgr]"
      echo "mgr/cephadm/container_image_prometheus = $(mirror_image "$(list_official_monitor_images | sed -n '1p')")"
      echo "mgr/cephadm/container_image_alertmanager = $(mirror_image "$(list_official_monitor_images | sed -n '2p')")"
      echo "mgr/cephadm/container_image_node_exporter = $(mirror_image "$(list_official_monitor_images | sed -n '3p')")"
      echo "mgr/cephadm/container_image_grafana = $(mirror_image "$(list_official_monitor_images | sed -n '4p')")"
    } >"${cfg_tmp}"
    args+=(--config "${cfg_tmp}")
  fi

  item "cephadm bootstrap  --image ${ceph_img}"
  if cephadm "${args[@]}"; then
    :
  else
    [[ -n "${cfg_tmp}" ]] && rm -f "${cfg_tmp}"
    err "bootstrap 失败"
  fi
  [[ -n "${cfg_tmp}" ]] && rm -f "${cfg_tmp}"

  cephadm install ceph-common || true
  mkdir -p /root/.ceph
  chmod 700 /etc/ceph
  ok "集群已创建"
  ok "Dashboard  https://${bip}:8443  admin"
  item "密码见 bootstrap 输出，或: ceph dashboard ac-user-show admin"
  run_ceph -s || true
}

cmd_add_hosts() {
  need_root add-hosts
  [[ -f /etc/ceph/ceph.conf ]] || err "请先在 bootstrap 节点执行 bootstrap"
  step "add-hosts"
  local ip host role user pass disks
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    if [[ "$(echo "${role}" | tr 'A-Z' 'a-z')" == "bootstrap" ]]; then
      skip "${host}  已是 bootstrap"
      continue
    fi
    if run_ceph orch host add "${host}" "${ip}"; then
      ok "${host}  ${ip}"
    else
      warn "${host}  加入失败（可能已在集群中）"
    fi
  done < <(list_ssh_nodes)
  run_ceph orch host ls
  sync_csi_example_from_conf
}

cmd_osd() {
  need_root osd
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap"
  step "osd"
  local use_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all-available-devices) use_all=1; shift ;;
      *) err "用法: $0 osd [--all-available-devices]" ;;
    esac
  done

  if [[ "${use_all}" == "1" ]]; then
    [[ "${OSD_ALLOW_ALL}" == "1" ]] || err "须在 conf 设 OSD_ALLOW_ALL=1，且盘上无数据"
    warn "将清空所有空闲块设备做 OSD"
    run_ceph orch apply osd --all-available-devices
    run_ceph osd tree
    return 0
  fi

  local ip host role user pass disks d
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    disks="$(printf '%s' "${disks:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${disks}" ]] || { skip "${host}  未配 OSD 盘"; continue; }
    IFS=',' read -ra _devs <<<"${disks}"
    for d in "${_devs[@]}"; do
      d="$(printf '%s' "${d}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "${d}" ]] || continue
      if run_ceph orch daemon add osd "${host}:${d}"; then
        ok "${host}:${d}"
      else
        fail "${host}:${d}  盘占用或路径不对"
      fi
    done
  done < <(list_ssh_nodes)
  sleep 3
  run_ceph osd tree || true
  run_ceph -s || true
}

cmd_pool() {
  need_root pool
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap"
  step "pool  ${RBD_POOL}"
  if run_ceph osd pool ls | grep -qx "${RBD_POOL}"; then
    skip "池已存在"
  else
    item "创建  pg=${RBD_PG_NUM}  size=3"
    run_ceph osd pool create "${RBD_POOL}" "${RBD_PG_NUM}"
    run_ceph osd pool application enable "${RBD_POOL}" rbd
    run_ceph osd pool set "${RBD_POOL}" size 3 || true
    run_ceph osd pool set "${RBD_POOL}" min_size 2 || true
    ok "池 ${RBD_POOL}"
  fi
  if command -v rbd >/dev/null 2>&1; then
    rbd pool init "${RBD_POOL}" || true
  else
    cephadm shell -- rbd pool init "${RBD_POOL}" || true
  fi
  if run_ceph auth get client.kubernetes >/dev/null 2>&1; then
    skip "client.kubernetes 已存在"
  else
    item "创建 client.kubernetes"
    run_ceph auth get-or-create client.kubernetes \
      mon "profile rbd" \
      osd "profile rbd pool=${RBD_POOL}" \
      mgr "profile rbd pool=${RBD_POOL}"
    ok "client.kubernetes"
  fi
  sync_csi_example_from_conf
}

cmd_status() {
  step "status  ${CEPH_RELEASE}  池 ${RBD_POOL}"
  if [[ -f /etc/ceph/ceph.conf ]]; then
    run_ceph -s
    echo
    run_ceph orch host ls || true
    echo
    run_ceph osd tree || true
  else
    warn "本机无 ceph.conf，只列节点表"
  fi
  echo
  list_node_lines | awk -F'|' '{printf "  ·  %s  %s  [%s]  %s\n", $2, $1, $3, $6}'
}

cmd_export_rbd() {
  need_root export-rbd
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap / pool"
  step "export-rbd"
  local out key
  out="${SCRIPT_DIR}/csi/generated"
  mkdir -p "${out}"
  key="$(run_ceph auth get-key client.kubernetes 2>/dev/null || true)"
  [[ -n "${key}" ]] || err "没有 client.kubernetes，请先执行 pool"
  sync_csi_example_from_conf
  write_csi_secret_yaml "${out}/secret.yaml" "${key}"
  chmod 600 "${out}/secret.yaml"
  ok "${out}/secret.yaml  （含密钥，勿提交 git）"
  item "kubectl apply -f ${out}/secret.yaml"
  item "kubectl apply -f ${SCRIPT_DIR}/csi/storageclass-rbd.yaml"
}

cmd_help() {
  local bin
  bin="$(basename "$0")"
  cat <<EOF

  install-ceph  ·  Ubuntu 24 + cephadm（独立集群，RBD）
  ────────────────────────────────────────────────────────
  版本  CEPH_RELEASE=${CEPH_RELEASE}    池  ${RBD_POOL}
  配置  ${CEPH_NODES_FILE}
  镜像  IMAGE_MIRROR=${IMAGE_MIRROR:-（官方 quay.io）}  SKIP_MONITORING_STACK=${SKIP_MONITORING_STACK}

  用法
    bash ${bin} --help              本帮助
    bash ${bin} -h
    bash ${bin} help                同上
    bash ${bin} help <命令>         某命令详情
    bash ${bin} <命令> --help       同上
    bash ${bin} <命令> -h

  安装顺序（均在 bootstrap 节点 ceph1 操作远程即可）
    改 conf → ssh-keys → prepare-all → hosts-all
    → bootstrap → add-hosts → osd → pool → status

  命令
    查看 / 准备
      help / --help  本说明；help <命令> 看详情
      images         打印本部署需要的 Docker 镜像（不必 root）
      prepare        本机：docker、chrony、lvm2、cephadm
      prepare-all    按 conf 远程 prepare（含本机）
      hosts          本机写入 /etc/hosts
      hosts-all      全部节点刷新 hosts，并按 conf 更新 CSI example
      ssh-keys       按 conf 分发 SSH 免密（cephadm 编排依赖）

    集群
      bootstrap      仅 bootstrap 节点：MON / MGR / Dashboard
      add-hosts      将其余 conf 节点加入 cephadm
      osd            按节点表第 6 列磁盘创建 OSD
      pool           创建 RBD 池与 client.kubernetes
      status         ceph -s / host / osd tree

    CSI（业务 K8s）
      csi-example    按 conf 刷新 csi/secret.yaml.example 的 monitors
      export-rbd     导出含真实 key 的 Secret（monitors 来自 conf）

  配置要点（改 conf，不要改脚本）
    节点   IP|主机名|角色|用户|密码|osd磁盘
    角色   bootstrap 只能一行；其余 node
    OSD    第 6 列必须是独立空盘（如 /dev/vdb），禁止系统盘
    监控   SKIP_MONITORING_STACK=1 可跳过 cephadm 自带 Prometheus
    镜像   IMAGE_MIRROR=registry.../starbucket（容器）；CEPH_APT_MIRROR=https://.../debian-xxx（仅 apt）

  不要装在业务 K8s Master/Worker 上。三副本至少 3 台、每台一块 OSD。

EOF
}

usage_cmd() {
  local c="$1"
  local bin
  bin="$(basename "$0")"
  case "${c}" in
    help|--help|-h)
      cmd_help
      ;;
    images)
      cat <<EOF

  命令  images
  ────────────────────────────────
  作用  打印当前部署会拉的容器镜像及本机是否已有
  用法  bash ${bin} images
        bash ${bin} images --help
  说明  第 1 个为 Ceph 主镜像（每台都要）；其余为监控栈（可 SKIP_MONITORING_STACK=1 跳过）
  配置  CEPH_RELEASE=${CEPH_RELEASE}  IMAGE_MIRROR=${IMAGE_MIRROR:-（官方 quay.io）}
        CEPH_IMAGE=${CEPH_IMAGE:-（由发行版 + IMAGE_MIRROR 推导）}

EOF
      ;;
    prepare)
      cat <<EOF

  命令  prepare
  ────────────────────────────────
  作用  本机准备：主机名、hosts、chrony、docker、cephadm，并打印镜像列表；预拉 Ceph 主镜像
  用法  sudo bash ${bin} prepare
        sudo bash ${bin} prepare --help
  说明  每台存储节点都要；从 ceph1 批量请用 prepare-all
  镜像  开始时打印列表，同 images

EOF
      ;;
    prepare-all)
      cat <<EOF

  命令  prepare-all
  ────────────────────────────────
  作用  按 ceph-nodes.conf 把脚本同步到各节点并远程执行 prepare
  用法  sudo bash ${bin} prepare-all
        sudo bash ${bin} prepare-all --help
  前提  建议先 ssh-keys；否则需 conf 中真实 root 密码（sshpass）
  远程  脚本放到 ${REMOTE_DIR}

EOF
      ;;
    hosts)
      cat <<EOF

  命令  hosts
  ────────────────────────────────
  作用  按 conf 刷新本机 /etc/hosts（# ceph-cluster 段）并可改主机名
  用法  sudo bash ${bin} hosts
        sudo bash ${bin} hosts --help

EOF
      ;;
    hosts-all)
      cat <<EOF

  命令  hosts-all
  ────────────────────────────────
  作用  对 conf 全部节点远程执行 hosts，并按 conf 刷新 csi/secret.yaml.example
  用法  sudo bash ${bin} hosts-all
        sudo bash ${bin} hosts-all --help
  前提  ssh-keys 或 conf 密码

EOF
      ;;
    ssh-keys)
      cat <<EOF

  命令  ssh-keys
  ────────────────────────────────
  作用  按 conf 用 sshpass 分发 root 公钥，并尽量做到节点互免密（cephadm 编排需要）
  用法  sudo bash ${bin} ssh-keys
        sudo bash ${bin} ssh-keys --help
  说明  密码占位符「请改成真实密码」的节点会跳过

EOF
      ;;
    bootstrap)
      cat <<EOF

  命令  bootstrap
  ────────────────────────────────
  作用  仅在 role=bootstrap 那台创建集群（MON/MGR/Dashboard）
  用法  sudo bash ${bin} bootstrap
        sudo bash ${bin} bootstrap --help
  选项  conf：IMAGE_MIRROR、CEPH_IMAGE、CLUSTER_NETWORK、DASHBOARD_PASSWORD、SKIP_MONITORING_STACK
  说明  必须在 bootstrap 节点本机执行；已有 /etc/ceph/ceph.conf 且 ceph -s 可用则跳过
        IMAGE_MIRROR 时 --image 与监控栈都会走该前缀；CEPH_APT_MIRROR 只影响 apt
  访问  https://<bootstrap-ip>:8443  用户 admin

EOF
      ;;
    add-hosts)
      cat <<EOF

  命令  add-hosts
  ────────────────────────────────
  作用  把 conf 里非 bootstrap 节点 ceph orch host add 进集群，并刷新 CSI example
  用法  sudo bash ${bin} add-hosts
        sudo bash ${bin} add-hosts --help
  前提  已 bootstrap；目标机已 prepare 且与 ceph1 免密
  扩容  在 conf 追加 node 行后，再跑 ssh-keys → prepare-all → hosts-all → add-hosts → osd

EOF
      ;;
    osd)
      cat <<EOF

  命令  osd
  ────────────────────────────────
  作用  按节点表第 6 列块设备在对应主机创建 OSD（会清空该盘）
  用法  sudo bash ${bin} osd
        sudo bash ${bin} osd --all-available-devices
        sudo bash ${bin} osd --help
  选项  --all-available-devices  领取所有空闲盘；必须 conf OSD_ALLOW_ALL=1
  禁止  系统盘（vda/sda 上的 /）、有数据的盘
  盘符  以目标机 lsblk 为准，虚拟机常见 /dev/vdb 而不是 /dev/sdb

EOF
      ;;
    pool)
      cat <<EOF

  命令  pool
  ────────────────────────────────
  作用  创建 RBD 池（默认 ${RBD_POOL}）、三副本，以及 CSI 用户 client.kubernetes
  用法  sudo bash ${bin} pool
        sudo bash ${bin} pool --help
  配置  RBD_POOL  RBD_PG_NUM  size=3 min_size=2
  随后  export-rbd 才能导出 CSI Secret

EOF
      ;;
    status)
      cat <<EOF

  命令  status
  ────────────────────────────────
  作用  打印 ceph -s、orch host、osd tree 以及 conf 节点表（不含密码）
  用法  bash ${bin} status
        bash ${bin} status --help
  说明  无 /etc/ceph/ceph.conf 时只打印节点表

EOF
      ;;
    export-rbd)
      cat <<EOF

  命令  export-rbd
  ────────────────────────────────
  作用  读取 client.kubernetes 密钥，按 conf 节点 IP 生成 CSI Secret/ConfigMap
  用法  sudo bash ${bin} export-rbd
        sudo bash ${bin} export-rbd --help
  产出  csi/generated/secret.yaml（含密钥，勿提交 git）
        同时刷新 csi/secret.yaml.example（monitors 来自 conf，key 为占位符）
  前提  已 pool；在业务集群 kubectl apply generated 文件 + storageclass-rbd.yaml

EOF
      ;;
    csi-example)
      cat <<EOF

  命令  csi-example
  ────────────────────────────────
  作用  只根据 ceph-nodes.conf 重写 csi/secret.yaml.example 的 monitors（不必装集群）
  用法  bash ${bin} csi-example
        bash ${bin} csi-example --help
  说明  改节点 IP 后先跑本命令，不要手改 YAML 里的 6789 地址
  密钥  占位符；真实 key 用 export-rbd

EOF
      ;;
    *)
      warn "没有命令「${c}」的说明"
      echo "  用法: bash ${bin} help <命令>   或  bash ${bin} <命令> --help"
      echo "  总览: bash ${bin} --help"
      ;;
  esac
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    -h|--help|help)
      if [[ $# -gt 0 && "${1}" != "-h" && "${1}" != "--help" ]]; then
        usage_cmd "${1}"
      else
        cmd_help
      fi
      return 0
      ;;
  esac
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage_cmd "${cmd}"
    return 0
  fi
  case "${cmd}" in
    images)         cmd_images ;;
    prepare)        cmd_prepare "$@" ;;
    prepare-all)    cmd_prepare_all "$@" ;;
    hosts)          cmd_hosts "$@" ;;
    hosts-all)      cmd_hosts_all "$@" ;;
    ssh-keys)       cmd_ssh_keys "$@" ;;
    bootstrap)      cmd_bootstrap "$@" ;;
    add-hosts)      cmd_add_hosts "$@" ;;
    osd)            cmd_osd "$@" ;;
    pool)           cmd_pool "$@" ;;
    status)         cmd_status "$@" ;;
    export-rbd)     cmd_export_rbd "$@" ;;
    csi-example)    cmd_csi_example "$@" ;;
    *) err "未知命令: ${cmd}（bash $0 --help  或  bash $0 help <命令>）" ;;
  esac
}

main "$@"
