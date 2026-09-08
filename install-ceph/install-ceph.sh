#!/usr/bin/env bash
# Ubuntu 24 + cephadm 独立 Ceph 集群（RBD），与业务 Kubernetes 分开部署
# 用法: bash install-ceph.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEPH_NODES_FILE="${CEPH_NODES_FILE:-${SCRIPT_DIR}/ceph-nodes.conf}"
REMOTE_DIR="/opt/service/ceph"

CEPH_RELEASE_DEFAULT="reef"
RBD_POOL_DEFAULT="kubernetes"
RBD_PG_NUM_DEFAULT="32"

_CONF_CEPH_RELEASE=""
_CONF_CEPH_APT_MIRROR=""
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

[[ -f "${CEPH_NODES_FILE}" ]] || {
  echo -e "\033[0;31m[ERROR]\033[0m 缺少 ${CEPH_NODES_FILE}" >&2
  exit 1
}
load_conf_kv "${CEPH_NODES_FILE}"

CEPH_RELEASE="${CEPH_RELEASE:-${_CONF_CEPH_RELEASE:-${CEPH_RELEASE_DEFAULT}}}"
CEPH_APT_MIRROR="${CEPH_APT_MIRROR:-${_CONF_CEPH_APT_MIRROR:-}}"
CEPH_IMAGE="${CEPH_IMAGE:-${_CONF_CEPH_IMAGE:-}}"
RBD_POOL="${RBD_POOL:-${_CONF_RBD_POOL:-${RBD_POOL_DEFAULT}}}"
RBD_PG_NUM="${RBD_PG_NUM:-${_CONF_RBD_PG_NUM:-${RBD_PG_NUM_DEFAULT}}}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-${_CONF_CLUSTER_NETWORK:-}}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-${_CONF_DASHBOARD_PASSWORD:-}}"
OSD_ALLOW_ALL="${OSD_ALLOW_ALL:-${_CONF_OSD_ALLOW_ALL:-0}}"
SKIP_MONITORING_STACK="${SKIP_MONITORING_STACK:-${_CONF_SKIP_MONITORING_STACK:-0}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_root() {
  [[ $EUID -eq 0 ]] || err "请使用 root 执行：sudo bash $0 $*"
}

# 本脚本实际会拉的镜像（不含 cephadm list-images 里未启用的 ingress/jaeger 等）
default_ceph_image() {
  if [[ -n "${CEPH_IMAGE}" ]]; then
    printf '%s' "${CEPH_IMAGE}"
    return
  fi
  case "${CEPH_RELEASE}" in
    squid) printf '%s' "quay.io/ceph/ceph:v19" ;;
    *)     printf '%s' "quay.io/ceph/ceph:v18" ;;
  esac
}

list_deploy_images() {
  default_ceph_image
  echo
  if [[ "${SKIP_MONITORING_STACK}" != "1" ]]; then
    case "${CEPH_RELEASE}" in
      squid)
        echo "quay.io/prometheus/prometheus:v2.51.0"
        echo "quay.io/prometheus/alertmanager:v0.27.0"
        echo "quay.io/prometheus/node-exporter:v1.7.0"
        echo "quay.io/ceph/ceph-grafana:9.4.7"
        ;;
      *)
        echo "quay.io/prometheus/prometheus:v2.43.0"
        echo "quay.io/prometheus/alertmanager:v0.25.0"
        echo "quay.io/prometheus/node-exporter:v1.5.0"
        echo "quay.io/ceph/ceph-grafana:9.4.7"
        ;;
    esac
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
  local img n=0
  echo
  log "当前部署需要的镜像  CEPH_RELEASE=${CEPH_RELEASE}  SKIP_MONITORING_STACK=${SKIP_MONITORING_STACK}"
  if [[ -n "${CEPH_IMAGE}" ]]; then
    echo "  CEPH_IMAGE=${CEPH_IMAGE}（conf 覆盖默认 quay.io/ceph/ceph）"
  fi
  printf "  %-8s  %s\n" "状态" "镜像"
  while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    n=$((n + 1))
    printf "  %-8s  %s\n" "$(image_pull_status "${img}")" "${img}"
  done < <(list_deploy_images)
  echo
  echo "  说明: 第 1 个镜像每台节点都要有（MON/MGR/OSD 共用）。"
  if [[ "${SKIP_MONITORING_STACK}" != "1" ]]; then
    echo "        其余为 cephadm 自带监控栈（Prometheus/Grafana 等），bootstrap 时拉取。"
    echo "        已有业务监控可在 conf 设 SKIP_MONITORING_STACK=1 跳过。"
  else
    echo "        已跳过 cephadm 监控栈，只拉 Ceph 主镜像。"
  fi
  echo "  单独打印: bash $(basename "$0") images"
  echo
}

cmd_images() {
  print_image_list
  echo "---- 纯镜像列表（可复制）----"
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

ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  log "安装 sshpass"
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
    log "设置主机名 ${host}"
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
  print_image_list
  maybe_set_hostname
  apply_hosts

  log "安装基础包（chrony / lvm2 / docker / cephadm）"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lvm2 chrony docker.io

  systemctl enable --now chrony
  systemctl enable --now docker

  install_ceph_repo
  apt-get install -y cephadm ceph-common

  local img
  img="$(default_ceph_image)"
  log "预拉 Ceph 主镜像 ${img}"
  docker pull "${img}" || warn "镜像预拉失败，bootstrap 时再试"

  timedatectl set-ntp true || true
  log "prepare 完成：$(hostname) $(hostname -I | awk '{print $1}')"
}

cmd_prepare() { do_prepare; }

cmd_hosts() {
  need_root hosts
  maybe_set_hostname
  apply_hosts
  log "已写入 /etc/hosts"
  grep -A20 'ceph-cluster BEGIN' /etc/hosts || true
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
  log "结束：成功=${n_ok} 失败=${n_fail}"
  [[ "${n_fail}" -eq 0 ]]
}

_remote_cmd() {
  local cmd="$1" ip="$2" host="$3" role="$4" user="$5" pass="$6"
  log "======== ${user}@${ip} (${host}) [${role}] ========"
  if is_local_ip "${ip}"; then
    bash "${SCRIPT_DIR}/install-ceph.sh" "${cmd}"
    return $?
  fi
  if [[ -z "${pass}" ]] && ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "true" 2>/dev/null; then
    warn "跳过 ${ip}：无密码且无法免密 SSH（请先 ssh-keys）"
    return 1
  fi
  if placeholder_pass "${pass}"; then
    warn "${ip} 密码仍是占位符，请改 ceph-nodes.conf"
    return 1
  fi
  sync_install_to_node "${user}" "${ip}" "${pass}" || return 1
  remote_ssh "${user}" "${ip}" "${pass}" "cd ${REMOTE_DIR} && bash install-ceph.sh ${cmd}"
}

cmd_prepare_all() {
  need_root prepare-all
  ensure_sshpass
  print_image_list
  _wrap_prepare() { _remote_cmd prepare "$@"; }
  for_each_node _wrap_prepare
}

cmd_hosts_all() {
  need_root hosts-all
  ensure_sshpass
  _wrap_hosts() { _remote_cmd hosts "$@"; }
  for_each_node _wrap_hosts
}

cmd_ssh_keys() {
  need_root ssh-keys
  ensure_sshpass
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f /root/.ssh/id_rsa ]]; then
    log "生成本机 root RSA 密钥"
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -C "ceph-root@$(hostname)"
  fi
  chmod 600 /root/.ssh/id_rsa
  chmod 644 /root/.ssh/id_rsa.pub
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  local pub
  pub="$(cat /root/.ssh/id_rsa.pub)"
  grep -qxF "${pub}" /root/.ssh/authorized_keys || echo "${pub}" >>/root/.ssh/authorized_keys

  local count ip host role user pass errf
  count="$(node_count)"
  [[ "${count}" -ge 1 ]] || err "节点表为空"
  errf="$(mktemp)"
  log "向 ${count} 台节点分发公钥"
  while IFS='|' read -r ip host role user pass disks || [[ -n "${ip:-}" ]]; do
    [[ -n "${ip}" ]] || continue
    pass="$(printf '%s' "${pass:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    if is_local_ip "${ip}"; then
      log "跳过本机 ${ip}"
      continue
    fi
    if [[ -z "${pass}" ]] || placeholder_pass "${pass}"; then
      warn "${ip} 未填真实密码，跳过"
      continue
    fi
    log "ssh-copy-id ${user}@${ip} (${host})"
    : >"${errf}"
    if SSHPASS="${pass}" sshpass -e ssh-copy-id -i /root/.ssh/id_rsa.pub \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${user}@${ip}" </dev/null >/dev/null 2>"${errf}"; then
      log "  OK ${ip}"
    else
      warn "  FAIL ${ip}: $(tr '\n' ' ' <"${errf}" | cut -c1-180)"
    fi
    SSHPASS="${pass}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
      "${user}@${ip}" \
      'mkdir -p /root/.ssh; chmod 700 /root/.ssh; test -f /root/.ssh/id_rsa || ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa' \
      </dev/null >/dev/null 2>&1 || true
  done < <(list_ssh_nodes)
  rm -f "${errf}"

  log "合并各节点公钥（互通免密）"
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
    scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 \
      "${tmp_bundle}" "${user}@${ip}:/tmp/ceph_authorized_bundle" </dev/null 2>/dev/null \
      && scp "${SSH_OPTS[@]}" -o BatchMode=yes "${merge_sh}" "${user}@${ip}:/tmp/ceph_merge_keys.sh" </dev/null 2>/dev/null \
      && ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "${user}@${ip}" "bash /tmp/ceph_merge_keys.sh; rm -f /tmp/ceph_merge_keys.sh" \
      && log "已合并密钥到 ${ip}" \
      || warn "合并密钥到 ${ip} 失败"
  done < <(list_ssh_nodes)
  rm -f "${tmp_bundle}" "${merge_sh}"
  log "ssh-keys 完成"
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
  is_local_ip "${bip}" || err "bootstrap 必须在 ${bhost} (${bip}) 上执行"

  print_image_list

  if [[ -f /etc/ceph/ceph.conf ]] && run_ceph -s >/dev/null 2>&1; then
    log "集群已存在，跳过 bootstrap（ceph -s 可用）"
    run_ceph -s
    return 0
  fi

  [[ "$(node_count)" -ge 3 ]] || warn "节点不足 3 台，MON 法定人数与三副本 RBD 都不完整"

  local args=(bootstrap --mon-ip "${bip}" --ssh-user root --allow-fqdn-hostname)
  [[ -n "${CLUSTER_NETWORK}" ]] && args+=(--cluster-network "${CLUSTER_NETWORK}")
  [[ -n "${CEPH_IMAGE}" ]] && args+=(--image "${CEPH_IMAGE}")
  if [[ -n "${DASHBOARD_PASSWORD}" ]]; then
    args+=(--initial-dashboard-password "${DASHBOARD_PASSWORD}" --dashboard-password-noupdate)
  fi
  if [[ "${SKIP_MONITORING_STACK}" == "1" ]]; then
    args+=(--skip-monitoring-stack)
  fi

  log "cephadm ${args[*]}"
  cephadm "${args[@]}"

  cephadm install ceph-common || true
  mkdir -p /root/.ceph
  chmod 700 /etc/ceph
  log "bootstrap 完成"
  run_ceph -s || true
  echo
  log "Dashboard: https://${bip}:8443  （用户 admin）"
  echo "查看密码: ceph dashboard ac-user-show admin  或 bootstrap 日志"
}

cmd_add_hosts() {
  need_root add-hosts
  [[ -f /etc/ceph/ceph.conf ]] || err "请先在 bootstrap 节点执行 bootstrap"
  local ip host role user pass disks
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    if [[ "$(echo "${role}" | tr 'A-Z' 'a-z')" == "bootstrap" ]]; then
      log "bootstrap 节点已在集群中: ${host}"
      continue
    fi
    log "ceph orch host add ${host} ${ip}"
    run_ceph orch host add "${host}" "${ip}" || warn "host add ${host} 失败（可能已存在）"
  done < <(list_ssh_nodes)
  run_ceph orch host ls
}

cmd_osd() {
  need_root osd
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap"
  local use_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all-available-devices) use_all=1; shift ;;
      *) err "用法: $0 osd [--all-available-devices]" ;;
    esac
  done

  if [[ "${use_all}" == "1" ]]; then
    [[ "${OSD_ALLOW_ALL}" == "1" ]] || err "使用全部空闲盘须在 conf 设 OSD_ALLOW_ALL=1，且确认盘上无数据"
    warn "将领取所有未用块设备做 OSD（不可逆）"
    run_ceph orch apply osd --all-available-devices
    run_ceph osd tree
    return 0
  fi

  local ip host role user pass disks d
  while IFS='|' read -r ip host role user pass disks; do
    [[ -n "${ip}" ]] || continue
    disks="$(printf '%s' "${disks:-}" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${disks}" ]] || { log "${host} 未配置 OSD 盘，跳过"; continue; }
    IFS=',' read -ra _devs <<<"${disks}"
    for d in "${_devs[@]}"; do
      d="$(printf '%s' "${d}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "${d}" ]] || continue
      log "OSD ${host}:${d}"
      run_ceph orch daemon add osd "${host}:${d}" || warn "${host}:${d} 失败（设备已占用或路径不对）"
    done
  done < <(list_ssh_nodes)
  sleep 3
  run_ceph osd tree || true
  run_ceph -s || true
}

cmd_pool() {
  need_root pool
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap"
  if run_ceph osd pool ls | grep -qx "${RBD_POOL}"; then
    log "池 ${RBD_POOL} 已存在"
  else
    log "创建 RBD 池 ${RBD_POOL} pg=${RBD_PG_NUM}"
    run_ceph osd pool create "${RBD_POOL}" "${RBD_PG_NUM}"
    run_ceph osd pool application enable "${RBD_POOL}" rbd
    run_ceph osd pool set "${RBD_POOL}" size 3 || true
    run_ceph osd pool set "${RBD_POOL}" min_size 2 || true
  fi
  # rbd pool init
  if command -v rbd >/dev/null 2>&1; then
    rbd pool init "${RBD_POOL}" || true
  else
    cephadm shell -- rbd pool init "${RBD_POOL}" || true
  fi
  if run_ceph auth get client.kubernetes >/dev/null 2>&1; then
    log "client.kubernetes 已存在"
  else
    log "创建 client.kubernetes（CSI 用）"
    run_ceph auth get-or-create client.kubernetes \
      mon "profile rbd" \
      osd "profile rbd pool=${RBD_POOL}" \
      mgr "profile rbd pool=${RBD_POOL}"
  fi
  run_ceph osd pool ls detail | grep -A6 "pool '${RBD_POOL}'" || run_ceph osd lspools
}

cmd_status() {
  if [[ -f /etc/ceph/ceph.conf ]]; then
    run_ceph -s
    echo
    run_ceph orch host ls || true
    echo
    run_ceph osd tree || true
  else
    warn "本机无 /etc/ceph/ceph.conf，仅打印节点表"
  fi
  echo
  log "节点表 ${CEPH_NODES_FILE}  release=${CEPH_RELEASE}  pool=${RBD_POOL}"
  list_node_lines | awk -F'|' '{printf "  %s  %s  [%s]  osd=%s\n", $1, $2, $3, $6}'
}

cmd_export_rbd() {
  need_root export-rbd
  [[ -f /etc/ceph/ceph.conf ]] || err "请先 bootstrap / pool"
  local out key mons
  out="${SCRIPT_DIR}/csi/generated"
  mkdir -p "${out}"
  key="$(run_ceph auth get-key client.kubernetes 2>/dev/null || true)"
  [[ -n "${key}" ]] || err "没有 client.kubernetes，请先执行 pool"
  mons="$(list_node_lines | awk -F'|' '{printf "          \"%s:6789\",\n", $1}' | sed '$s/,$//')"
  cat >"${out}/secret.yaml" <<EOF
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
  chmod 600 "${out}/secret.yaml"
  log "已写入 ${out}/secret.yaml （含密钥，勿提交 git）"
  echo "业务集群："
  echo "  1. Helm 安装 ceph-csi RBD（namespace ceph-csi）"
  echo "  2. kubectl apply -f ${out}/secret.yaml"
  echo "  3. kubectl apply -f ${SCRIPT_DIR}/csi/storageclass-rbd.yaml"
}

cmd_help() {
  local bin
  bin="$(basename "$0")"
  cat <<EOF

独立 Ceph 集群（cephadm + RBD），不要装在业务 K8s 节点上。

顺序:
  改 ceph-nodes.conf → 全员 prepare → ssh-keys → hosts-all
  → bootstrap 节点: bootstrap → add-hosts → osd → pool → status

用法  sudo bash ${bin} <命令>

  prepare        本机：docker、chrony、lvm2、cephadm（开始时打印镜像列表）
  prepare-all    管理机：对 conf 全部节点执行 prepare
  images         打印当前部署需要的 Docker 镜像（不需要 root）
  prepare-all    管理机：对 conf 全部节点执行 prepare
  hosts          本机写入 /etc/hosts
  hosts-all      全部节点刷新 hosts
  ssh-keys       按 conf 分发 SSH 免密（cephadm 编排依赖）
  bootstrap      仅 bootstrap 节点：创建集群 / MON / MGR / Dashboard
  add-hosts      把其余节点加入 cephadm
  osd            按节点表第 6 列磁盘创建 OSD
                 --all-available-devices  需 conf OSD_ALLOW_ALL=1
  pool           创建 RBD 池 ${RBD_POOL} 与 client.kubernetes
  status         ceph -s / osd tree
  export-rbd     导出业务 K8s 用的 CSI Secret/ConfigMap
  help           本说明

配置  ${CEPH_NODES_FILE}
版本  CEPH_RELEASE=${CEPH_RELEASE}

OSD 盘必须是独立空盘，不要用系统盘。三副本至少 3 台、每台一块 OSD。

EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    -h|--help|help) cmd_help ;;
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
    *) err "未知命令: ${cmd}（bash $0 help）" ;;
  esac
}

main "$@"
