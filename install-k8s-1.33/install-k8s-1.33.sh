#!/usr/bin/env bash
# Ubuntu 24.04 一键准备 / 初始化 Kubernetes 1.33（kubeadm + containerd）
# 默认全部走国内镜像（apt / pause / 控制面镜像 / CNI yaml 代理）
# 用法见：K8s-1.33手动搭建指南.md
#
# 示例：
#   sudo bash install-k8s-1.33.sh prepare
#   sudo bash install-k8s-1.33.sh hosts
#   sudo bash install-k8s-1.33.sh vip --vip=172.16.10.114 --iface=eth0 --priority=100 --peers=172.16.10.115,172.16.10.116 --lb-port=8443
#   sudo bash install-k8s-1.33.sh init --apiserver-advertise-address=172.16.10.115 --control-plane-endpoint=172.16.10.114:8443
#   sudo bash install-k8s-1.33.sh cni-calico
#   sudo bash install-k8s-1.33.sh join-masters [--prepare]
#   sudo bash install-k8s-1.33.sh join-workers [--prepare]
#   sudo bash install-k8s-1.33.sh join-all

set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.33}"
KUBE_VERSION="${KUBE_VERSION:-}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

# ---------- 国内镜像默认配置（可用环境变量覆盖）----------
# Kubernetes apt 源（阿里云 kubernetes-new；注意是 /core/stable/ 斜杠路径，不是官方 core:/stable:/）
K8S_APT_MIRROR="${K8S_APT_MIRROR:-https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_MINOR}/deb/}"
K8S_APT_KEY_URL="${K8S_APT_KEY_URL:-https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_MINOR}/deb/Release.key}"
# 备用：官方 pkgs.k8s.io（国外，仅密钥/源失败时回退）
K8S_APT_MIRROR_FALLBACK="${K8S_APT_MIRROR_FALLBACK:-https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/}"
K8S_APT_KEY_FALLBACK="${K8S_APT_KEY_FALLBACK:-https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key}"
# kubeadm 控制面镜像仓库（对应 registry.k8s.io）
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-registry.aliyuncs.com/google_containers}"
# containerd sandbox / pause
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.10}"
# Docker Hub 加速（containerd hosts.toml）
DOCKER_MIRROR="${DOCKER_MIRROR:-https://docker.m.daocloud.io}"
# GitHub raw 代理（拉 CNI yaml；不可用可改 GH_PROXY="" 直连）
GH_PROXY="${GH_PROXY:-https://ghfast.top/}"
# Flannel 镜像（国内常用）
FLANNEL_IMAGE_REPO="${FLANNEL_IMAGE_REPO:-docker.m.daocloud.io/flannel}"
# VIP / Keepalived + HAProxy
VIP_IFACE="${VIP_IFACE:-}"
VIP_ROUTER_ID="${VIP_ROUTER_ID:-51}"
VIP_AUTH_PASS="${VIP_AUTH_PASS:-K8sVipPass33}"
# HAProxy 对外端口（避免与 kube-apiserver 的 6443 冲突）
LB_PORT="${LB_PORT:-8443}"

# ---------- 集群节点表（可配置多台，含 SSH 账号）----------
# 每行格式: IP|主机名|角色|用户名|密码
# 角色: vip | master | worker（vip 行用户/密码可留空）
# 密码勿含竖线 | ；含特殊字符一般可用，勿用单引号包一层进文件
#
# 【改法】编辑同目录 k8s-nodes.conf（推荐）后：
#   sudo bash install-k8s-1.33.sh hosts
#   sudo bash install-k8s-1.33.sh ssh-keys   # 按 conf 里账号密码自动互换密钥
#
# 安全：k8s-nodes.conf 含密码，权限建议 chmod 600，勿提交 git
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_NODES_FILE="${K8S_NODES_FILE:-${SCRIPT_DIR}/k8s-nodes.conf}"

_DEFAULT_K8S_NODES="$(cat <<'EOF'
172.16.10.114|k8s-vip|vip||
172.16.10.115|k8s-m1|master|root|ChangeMe
172.16.10.116|k8s-m2|master|root|ChangeMe
172.16.10.117|k8s-n1|worker|root|ChangeMe
EOF
)"

if [[ -z "${K8S_NODES:-}" && -f "${K8S_NODES_FILE}" ]]; then
  K8S_NODES="$(grep -vE '[[:space:]]*(#|$)' "${K8S_NODES_FILE}" || true)"
fi
K8S_NODES="${K8S_NODES:-${_DEFAULT_K8S_NODES}}"

SET_HOSTNAME="${SET_HOSTNAME:-1}"
SSH_PEERS="${SSH_PEERS:-}"

# 输出规范化节点行（保留密码中的字符，只去首尾空白与 CR）
list_nodes() {
  echo "${K8S_NODES}" | sed 's/\r$//' | grep -vE '^[[:space:]]*(#|$)' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

ips_by_role() {
  local role="$1"
  list_nodes | awk -F'|' -v r="${role}" 'tolower($3)==tolower(r) {print $1}'
}

ips_by_role_csv() {
  ips_by_role "$1" | paste -sd, -
}

default_vip_ip() {
  ips_by_role vip | head -n1
}

default_master_peers() {
  ips_by_role_csv master
}

# SSH 目标：master + worker（跳过 vip）
list_ssh_nodes() {
  list_nodes | awk -F'|' '
    BEGIN { OFS="|" }
    tolower($3)=="master" || tolower($3)=="worker" {
      user=($4==""?"root":$4)
      pass=$5
      print $1, $2, $3, user, pass
    }
  '
}

default_ssh_peers() {
  list_ssh_nodes | awk -F'|' '{print $1}' | paste -sd, -
}

hostname_for_ip() {
  local want="$1"
  list_nodes | awk -F'|' -v w="${want}" '
    $1==w && (tolower($3)=="master" || tolower($3)=="worker") {print $2; exit}
  '
}

is_local_ip() {
  local ip="$1"
  hostname -I 2>/dev/null | grep -qw "${ip}"
}

ensure_sshpass() {
  if command -v sshpass >/dev/null 2>&1; then
    return 0
  fi
  log "安装 sshpass（用于按 conf 密码非交互 SSH）"
  apt-get update -y >/dev/null
  apt-get install -y sshpass
}

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

check_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "当前系统为 ${ID:-unknown}，脚本按 Ubuntu 24 编写，请自行确认兼容性"
    fi
    log "系统: ${PRETTY_NAME:-unknown}"
  fi
}

gh_url() {
  local url="$1"
  if [[ -n "${GH_PROXY}" ]]; then
    # 已带代理前缀则不再加
    if [[ "${url}" == "${GH_PROXY}"* ]]; then
      echo "${url}"
    else
      echo "${GH_PROXY}${url}"
    fi
  else
    echo "${url}"
  fi
}

configure_containerd_mirrors() {
  log "配置 containerd 国内镜像加速 (certs.d)"
  mkdir -p /etc/containerd/certs.d/docker.io
  cat >/etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://docker.io"

[host."${DOCKER_MIRROR}"]
  capabilities = ["pull", "resolve"]

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
EOF

  # registry.k8s.io -> 阿里云（部分组件仍可能直连该域名）
  mkdir -p /etc/containerd/certs.d/registry.k8s.io
  cat >/etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF

  # gcr.io 常见依赖
  mkdir -p /etc/containerd/certs.d/gcr.io
  cat >/etc/containerd/certs.d/gcr.io/hosts.toml <<'EOF'
server = "https://gcr.io"

[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF

  # 确保 config.toml 使用 config_path
  if grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
    sed -i 's|config_path = ".*"|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
  else
    # 追加到 cri registry 段（兼容 default 配置）
    if ! grep -q '/etc/containerd/certs.d' /etc/containerd/config.toml; then
      cat >>/etc/containerd/config.toml <<'EOF'

# --- injected by install-k8s-1.33.sh ---
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
EOF
    fi
  fi
}

print_mirror_summary() {
  echo
  log "当前国内镜像配置："
  echo "  K8S apt      : ${K8S_APT_MIRROR}"
  echo "  控制面仓库   : ${IMAGE_REPOSITORY}"
  echo "  pause        : ${PAUSE_IMAGE}"
  echo "  Docker 加速  : ${DOCKER_MIRROR}"
  echo "  GitHub 代理  : ${GH_PROXY:-（直连）}"
  echo
  log "集群节点表（${K8S_NODES_FILE}）："
  printf "  %-16s %-14s %-8s %s\n" "IP" "HOSTNAME" "ROLE" "USER"
  list_nodes | while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    printf "  %-16s %-14s %-8s %s\n" "${ip}" "${host}" "${role}" "${user:-}"
  done
  echo "  VIP=$(default_vip_ip)  masters=$(default_master_peers)"
  echo
}

# 写入 /etc/hosts 托管段（可重复执行，幂等替换）
configure_hosts() {
  local marker_begin="# BEGIN K8S-1.33-CLUSTER"
  local marker_end="# END K8S-1.33-CLUSTER"
  local tmp ip host role
  tmp="$(mktemp)"
  if [[ -f /etc/hosts ]]; then
    awk -v b="${marker_begin}" -v e="${marker_end}" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' /etc/hosts >"${tmp}"
  else
    : >"${tmp}"
  fi
  {
    echo ""
    echo "${marker_begin}"
    while IFS='|' read -r ip host role user pass; do
      [[ -n "${ip}" && -n "${host}" ]] || continue
      echo "${ip} ${host}"
    done < <(list_nodes)
    echo "${marker_end}"
  } >>"${tmp}"
  cp "${tmp}" /etc/hosts
  rm -f "${tmp}"
  log "已更新 /etc/hosts："
  sed -n "/${marker_begin}/,/${marker_end}/p" /etc/hosts
}

maybe_set_hostname() {
  [[ "${SET_HOSTNAME}" == "1" ]] || return 0
  local ip host
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host="$(hostname_for_ip "${ip}")"
  if [[ -z "${host}" ]]; then
    warn "本机 IP=${ip} 不在节点表的 master/worker 中，跳过 hostnamectl"
    return 0
  fi
  if [[ "$(hostname)" != "${host}" ]]; then
    log "设置主机名: ${host}（本机 IP ${ip}）"
    hostnamectl set-hostname "${host}"
  else
    log "主机名已是 ${host}"
  fi
}

cmd_nodes() {
  log "当前节点规划（密码不显示）："
  printf "%-16s %-14s %-8s %s\n" "IP" "HOSTNAME" "ROLE" "USER"
  list_nodes | while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    printf "%-16s %-14s %-8s %s\n" "${ip}" "${host}" "${role}" "${user:-}"
  done
  echo
  echo "配置文件: ${K8S_NODES_FILE} $([ -f "${K8S_NODES_FILE}" ] && echo '(已加载)' || echo '(不存在则用内置默认)')"
  echo "VIP: $(default_vip_ip)"
  echo "Master peers: $(default_master_peers)"
  echo "SSH 目标:"
  list_ssh_nodes | while IFS='|' read -r ip host role user pass; do
    echo "  ${user}@${ip} (${host}, ${role})"
  done
}

cmd_hosts() {
  need_root hosts
  configure_hosts
  maybe_set_hostname
}

# 从 k8s-nodes.conf 读取 master/worker 的 IP/用户/密码，自动互换 SSH 密钥
cmd_ssh_keys() {
  need_root ssh-keys
  local mutual=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mutual) mutual=0; shift ;;
      --peers=*)
        err "已改为只读 k8s-nodes.conf，请在 conf 中配置节点；勿再使用 --peers"
        ;;
      *) err "用法: $0 ssh-keys [--no-mutual]" ;;
    esac
  done

  if [[ ! -f "${K8S_NODES_FILE}" ]]; then
    warn "未找到 ${K8S_NODES_FILE}，将使用内置默认节点表（请尽快创建 conf 并填写真实密码）"
  else
    log "读取节点配置: ${K8S_NODES_FILE}"
  fi

  local count
  count="$(list_ssh_nodes | grep -c . || true)"
  [[ "${count}" -ge 1 ]] || err "节点表中没有 master/worker，请编辑 ${K8S_NODES_FILE}"

  ensure_sshpass

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f /root/.ssh/id_rsa ]]; then
    log "生成本机 root RSA 密钥（无口令）"
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -C "k8s-root@$(hostname)"
  else
    log "已存在 /root/.ssh/id_rsa"
  fi
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_rsa
  chmod 644 /root/.ssh/id_rsa.pub
  local pub
  pub="$(cat /root/.ssh/id_rsa.pub)"
  grep -qxF "${pub}" /root/.ssh/authorized_keys || echo "${pub}" >>/root/.ssh/authorized_keys

  if ! grep -q 'StrictHostKeyChecking' /root/.ssh/config 2>/dev/null; then
    cat >>/root/.ssh/config <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 30
EOF
    chmod 600 /root/.ssh/config
  fi

  log "按 conf 向各节点分发本机公钥（sshpass，非交互）"
  local ip host role user pass
  while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    if is_local_ip "${ip}"; then
      log "跳过本机 ${user}@${ip} (${host})"
      continue
    fi
    if [[ -z "${pass}" ]]; then
      warn "${ip} (${host}) 未配置密码，跳过自动分发；请补全 conf 或手动 ssh-copy-id"
      continue
    fi
    log "ssh-copy-id ${user}@${ip} (${host})"
    if SSHPASS="${pass}" sshpass -e ssh-copy-id -i /root/.ssh/id_rsa.pub \
      -o StrictHostKeyChecking=no "${user}@${ip}" >/dev/null 2>&1; then
      log "  OK 已写入 ${ip}"
    else
      warn "  FAIL ${user}@${ip}（检查 conf 密码、sshd PermitRootLogin、网络）"
    fi
    # 远程若无密钥则生成，便于后续互通
    SSHPASS="${pass}" sshpass -e ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
      'mkdir -p /root/.ssh; chmod 700 /root/.ssh; test -f /root/.ssh/id_rsa || ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa' \
      >/dev/null 2>&1 || true
  done < <(list_ssh_nodes)

  if [[ "${mutual}" == "1" ]]; then
    log "收集各节点公钥并写回所有节点（互通免密）"
    local tmp_bundle merge_sh
    tmp_bundle="$(mktemp)"
    merge_sh="$(mktemp)"
    {
      echo "# k8s cluster keys $(date -Iseconds)"
      cat /root/.ssh/id_rsa.pub
    } >"${tmp_bundle}"

    while IFS='|' read -r ip host role user pass; do
      [[ -n "${ip}" ]] || continue
      is_local_ip "${ip}" && continue
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "cat /root/.ssh/id_rsa.pub" >>"${tmp_bundle}" 2>/dev/null; then
        :
      elif [[ -n "${pass}" ]]; then
        SSHPASS="${pass}" sshpass -e ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
          "cat /root/.ssh/id_rsa.pub" >>"${tmp_bundle}" 2>/dev/null || warn "无法获取 ${ip} 公钥"
      fi
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
done < /tmp/k8s_authorized_bundle
rm -f /tmp/k8s_authorized_bundle
EOS
    chmod +x "${merge_sh}"

    while IFS='|' read -r ip host role user pass; do
      [[ -n "${ip}" ]] || continue
      is_local_ip "${ip}" && continue
      if scp -o BatchMode=yes -o ConnectTimeout=5 \
          "${tmp_bundle}" "${user}@${ip}:/tmp/k8s_authorized_bundle" 2>/dev/null \
        && scp -o BatchMode=yes "${merge_sh}" "${user}@${ip}:/tmp/k8s_merge_keys.sh" 2>/dev/null \
        && ssh -o BatchMode=yes "${user}@${ip}" "bash /tmp/k8s_merge_keys.sh; rm -f /tmp/k8s_merge_keys.sh" 2>/dev/null; then
        log "已合并密钥到 ${user}@${ip}"
        continue
      fi
      if [[ -n "${pass}" ]]; then
        if SSHPASS="${pass}" sshpass -e scp -o StrictHostKeyChecking=no \
            "${tmp_bundle}" "${user}@${ip}:/tmp/k8s_authorized_bundle" \
          && SSHPASS="${pass}" sshpass -e scp -o StrictHostKeyChecking=no \
            "${merge_sh}" "${user}@${ip}:/tmp/k8s_merge_keys.sh" \
          && SSHPASS="${pass}" sshpass -e ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
            "bash /tmp/k8s_merge_keys.sh; rm -f /tmp/k8s_merge_keys.sh"; then
          log "已合并密钥到 ${user}@${ip}"
        else
          warn "合并密钥到 ${ip} 失败"
        fi
      else
        warn "无法推送密钥包到 ${ip}"
      fi
    done < <(list_ssh_nodes)
    rm -f "${tmp_bundle}" "${merge_sh}"
  fi

  echo
  log "免密测试（读取 conf 中的 master/worker）："
  while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    is_local_ip "${ip}" && continue
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "hostname" 2>/dev/null; then
      echo "  OK  ${user}@${ip} (${host})"
    else
      echo "  FAIL ${user}@${ip} (${host})"
    fi
  done < <(list_ssh_nodes)
}

cmd_prepare() {
  need_root prepare
  check_os
  print_mirror_summary

  log "0/7 写入集群 /etc/hosts 并按需设置主机名"
  configure_hosts
  maybe_set_hostname

  log "1/7 关闭 swap"
  swapoff -a || true
  sed -i '/ swap / s/^/#/' /etc/fstab || true

  log "2/7 内核模块与网络参数"
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  log "3/7 安装基础依赖"
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl gpg socat conntrack ipset ebtables ethtool

  log "4/7 安装并配置 containerd（含国内加速）"
  apt-get install -y containerd
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sed -i "s|sandbox_image = \".*\"|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml
  # 关闭 default 里可能存在的旧 mirrors 段冲突时仍以 config_path 为准
  configure_containerd_mirrors
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd

  log "5/7 添加 Kubernetes v${K8S_MINOR} 国内 apt 源"
  mkdir -p -m 755 /etc/apt/keyrings
  local apt_mirror="${K8S_APT_MIRROR}"
  local key_url="${K8S_APT_KEY_URL}"
  if ! curl -fsSL "${key_url}" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    warn "阿里云密钥失败，回退官方 pkgs.k8s.io"
    apt_mirror="${K8S_APT_MIRROR_FALLBACK}"
    key_url="${K8S_APT_KEY_FALLBACK}"
    curl -fsSL "${key_url}" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${apt_mirror} /" \
    >/etc/apt/sources.list.d/kubernetes.list
  log "apt 源: ${apt_mirror}"

  if ! apt-get update -y; then
    warn "当前 apt 源更新失败，切换到官方源重试"
    apt_mirror="${K8S_APT_MIRROR_FALLBACK}"
    curl -fsSL "${K8S_APT_KEY_FALLBACK}" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${apt_mirror} /" \
      >/etc/apt/sources.list.d/kubernetes.list
    apt-get update -y
  fi
  if [[ -n "${KUBE_VERSION}" ]]; then
    log "安装指定版本: ${KUBE_VERSION}"
    apt-get install -y \
      "kubelet=${KUBE_VERSION}" \
      "kubeadm=${KUBE_VERSION}" \
      "kubectl=${KUBE_VERSION}"
  else
    log "安装仓库内最新 v${K8S_MINOR}"
    apt-get install -y kubelet kubeadm kubectl
  fi
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet

  log "6/7 预拉取 pause（国内仓库）"
  if command -v ctr >/dev/null 2>&1; then
    ctr -n k8s.io images pull "${PAUSE_IMAGE}" \
      || warn "pause 拉取失败，请检查网络后手动: ctr -n k8s.io images pull ${PAUSE_IMAGE}"
  fi

  log "7/7 预拉取 kubeadm 控制面镜像（${IMAGE_REPOSITORY}）"
  local ver
  ver="$(kubeadm version -o short | sed 's/^v//')"
  kubeadm config images pull \
    --kubernetes-version "v${ver}" \
    --image-repository "${IMAGE_REPOSITORY}" \
    || warn "控制面镜像预拉取失败。请检查 IMAGE_REPOSITORY 后重试。"

  echo
  log "节点环境已就绪（国内镜像）"
  echo "  kubeadm : $(kubeadm version -o short)"
  echo "  kubelet : $(kubelet --version 2>/dev/null | awk '{print $2}')"
  echo "  kubectl : $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion:/ {print $2; exit}')"
  echo
  echo "下一步："
  echo "  首节点: sudo bash $0 init --apiserver-advertise-address=<本机IP>"
  echo "  其它节点: sudo bash $0 join <MASTER_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
}

cmd_init() {
  need_root init
  local advertise="" endpoint="" extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apiserver-advertise-address=*) advertise="${1#*=}"; shift ;;
      --control-plane-endpoint=*)     endpoint="${1#*=}"; shift ;;
      --pod-network-cidr=*)           POD_CIDR="${1#*=}"; shift ;;
      *) extra+=("$1"); shift ;;
    esac
  done

  [[ -n "${advertise}" ]] || err "必须指定 --apiserver-advertise-address=<IP>"

  local args=(
    init
    --kubernetes-version "v$(kubeadm version -o short | sed 's/^v//')"
    --apiserver-advertise-address "${advertise}"
    --pod-network-cidr "${POD_CIDR}"
    --service-cidr "${SERVICE_CIDR}"
    --cri-socket unix:///run/containerd/containerd.sock
    --image-repository "${IMAGE_REPOSITORY}"
    --upload-certs
  )
  [[ -n "${endpoint}" ]] && args+=(--control-plane-endpoint "${endpoint}")
  [[ ${#extra[@]} -gt 0 ]] && args+=("${extra[@]}")

  log "控制面镜像仓库: ${IMAGE_REPOSITORY}"
  log "执行: kubeadm ${args[*]}"
  kubeadm "${args[@]}"

  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  chmod 600 /root/.kube/config

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local home
    home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    mkdir -p "${home}/.kube"
    cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${home}/.kube"
  fi

  echo
  log "控制面初始化完成。实验架构建议下一步："
  echo "  1) 安装 CNI: sudo bash $0 cni-calico"
  echo "  2) 其余节点: sudo bash $0 join-masters / join-workers / join-all"
  echo "  详见 K8s-1.33搭建指南.md"
}

# 两台 Master 上安装 HAProxy（负载到各节点 :6443）+ Keepalived（VIP 漂移）
# 对外入口: VIP:LB_PORT（默认 8443），避免与本机 kube-apiserver :6443 抢端口
cmd_vip() {
  need_root vip
  local vip="" iface="${VIP_IFACE}" priority="100" peers="" lb_port="${LB_PORT}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vip=*)      vip="${1#*=}"; shift ;;
      --iface=*)    iface="${1#*=}"; shift ;;
      --priority=*) priority="${1#*=}"; shift ;;
      --peers=*)    peers="${1#*=}"; shift ;;
      --lb-port=*)  lb_port="${1#*=}"; shift ;;
      *) err "未知参数: $1（[--vip=] [--iface=] [--priority=] [--peers=] [--lb-port=8443]；省略则读节点表）" ;;
    esac
  done
  # 未传参时从节点表自动填充
  [[ -n "${vip}" ]] || vip="$(default_vip_ip)"
  [[ -n "${peers}" ]] || peers="$(default_master_peers)"
  [[ -n "${vip}" ]] || err "未指定 --vip= 且节点表中无 vip 角色"
  [[ -n "${peers}" ]] || err "未指定 --peers= 且节点表中无 master 角色"
  log "使用 VIP=${vip}  peers=${peers}"
  if [[ -z "${iface}" ]]; then
    iface="$(ip -br route show default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "${iface}" ]] || err "无法自动检测网卡，请传 --iface=eth0"
    log "自动检测到网卡: ${iface}"
  fi

  log "1/4 开启 ip_nonlocal_bind（允许未持有 VIP 时也可 bind VIP 端口）"
  cat >/etc/sysctl.d/99-vip-nonlocal.conf <<'EOF'
net.ipv4.ip_nonlocal_bind = 1
EOF
  sysctl --system >/dev/null

  log "2/4 安装 haproxy + keepalived"
  apt-get update -y
  apt-get install -y haproxy keepalived

  local backend_cfg=""
  local p
  IFS=',' read -ra _peers <<< "${peers}"
  for p in "${_peers[@]}"; do
    p="$(echo "${p}" | tr -d ' ')"
    [[ -n "${p}" ]] || continue
    backend_cfg+="    server m-${p//./-} ${p}:6443 check inter 3s fall 3 rise 2"$'\n'
  done

  log "3/4 写入 HAProxy（前端 ${vip}:${lb_port} → 后端 Masters:6443）"
  # init 前后端 6443 未起来会告警 “no server available”，属正常，不影响 haproxy 进程
  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4000
    daemon
    user haproxy
    group haproxy

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    option  redispatch
    timeout connect 5s
    timeout client  86400s
    timeout server  86400s
    timeout check   3s
    retries 3

frontend k8s-api-front
    bind ${vip}:${lb_port}
    mode tcp
    option tcplog
    default_backend k8s-api-back

backend k8s-api-back
    mode tcp
    balance roundrobin
    option tcp-check
    default-server inter 5s fall 5 rise 2
${backend_cfg}
EOF

  # 健康检查：只看 haproxy 进程（不看后端 6443，否则 init 前 VIP 抢不起来）
  mkdir -p /etc/keepalived
  cat >/etc/keepalived/check_haproxy.sh <<'EOF'
#!/bin/bash
pidof haproxy >/dev/null 2>&1 || exit 1
exit 0
EOF
  chown root:root /etc/keepalived/check_haproxy.sh
  chmod 700 /etc/keepalived/check_haproxy.sh

  if ! ip link show "${iface}" >/dev/null 2>&1; then
    err "网卡不存在: ${iface}。请用 ip -br a 查看后传 --iface=正确网卡名"
  fi

  log "4/4 写入 Keepalived（VIP=${vip}, priority=${priority}, iface=${iface}）"
  # 去掉 enable_script_security，避免 Ubuntu 上脚本权限导致 keepalived 起不来
  # 实验阶段不 track_script，保证 VIP 先漂起来；集群就绪后可自行打开 track
  cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id K8S_VIP_${VIP_ROUTER_ID}
    vrrp_skip_check_adv_addr
    vrrp_garp_interval 0
    vrrp_gna_interval 0
}

vrrp_instance VI_K8S {
    state BACKUP
    interface ${iface}
    virtual_router_id ${VIP_ROUTER_ID}
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${VIP_AUTH_PASS:0:8}
    }
    virtual_ipaddress {
        ${vip}
    }
}
EOF

  systemctl enable haproxy keepalived
  systemctl restart haproxy || true
  sleep 1
  if ! systemctl restart keepalived; then
    warn "keepalived 启动失败，打印最近日志："
    journalctl -u keepalived -n 40 --no-pager || true
    err "请检查 --iface 是否正确、配置文件语法。修复后: systemctl restart keepalived"
  fi
  sleep 2

  echo
  systemctl is-active haproxy keepalived || true
  echo
  log "HAProxy + Keepalived 已配置"
  echo "  VIP           : ${vip}"
  echo "  LB 端口       : ${lb_port}  （kubeadm 请用 --control-plane-endpoint=${vip}:${lb_port}）"
  echo "  网卡          : ${iface}"
  echo "  priority      : ${priority}（越大越优先抢 VIP）"
  echo "  后端 Master   : ${peers} → :6443"
  echo
  warn "HAProxy 提示 backend has no server available：在 kubeadm init 之前属正常（6443 尚未监听）"
  echo "验证："
  echo "  ping -c2 ${vip}"
  echo "  ip -br a | grep ${vip}          # 仅当前持有 VIP 的节点上有"
  echo "  ss -lntp | grep ${lb_port}"
  echo "  curl -k https://${vip}:${lb_port}/healthz   # 等 init 成功后再测，应返回 ok"
  warn "单机 vip 完成。多 Master 请用: sudo bash $0 vip-all   （管理机一键部署全部 Master）"
}

# 管理机一键：按 conf 给所有 master 安装 HAProxy+Keepalived（自动分配 priority）
remote_ssh() {
  local user="$1" ip="$2" pass="$3" cmd="$4"
  if is_local_ip "${ip}"; then
    bash -c "${cmd}"
    return $?
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "${user}@${ip}" "true" 2>/dev/null; then
    ssh -o BatchMode=yes -o ConnectTimeout=30 "${user}@${ip}" "${cmd}"
    return $?
  fi
  [[ -n "${pass}" ]] || return 1
  SSHPASS="${pass}" sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${user}@${ip}" "${cmd}"
}

remote_scp() {
  local user="$1" ip="$2" pass="$3" src="$4" dst="$5"
  if is_local_ip "${ip}"; then
    mkdir -p "$(dirname "${dst}")"
    cp -f "${src}" "${dst}"
    return $?
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "${user}@${ip}" "true" 2>/dev/null; then
    scp -o BatchMode=yes -o ConnectTimeout=30 "${src}" "${user}@${ip}:${dst}"
    return $?
  fi
  [[ -n "${pass}" ]] || return 1
  SSHPASS="${pass}" sshpass -e scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${src}" "${user}@${ip}:${dst}"
}

cmd_vip_all() {
  need_root vip-all
  local iface_arg="" lb_port="${LB_PORT}" dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface=*)   iface_arg="${1#*=}"; shift ;;
      --lb-port=*) lb_port="${1#*=}"; shift ;;
      --dry-run)   dry=1; shift ;;
      *) err "用法: $0 vip-all [--iface=网卡] [--lb-port=8443] [--dry-run]" ;;
    esac
  done

  local vip peers
  vip="$(default_vip_ip)"
  peers="$(default_master_peers)"
  [[ -n "${vip}" ]] || err "节点表无 vip"
  [[ -n "${peers}" ]] || err "节点表无 master"

  if [[ ! -f "${K8S_NODES_FILE}" ]]; then
    err "需要 ${K8S_NODES_FILE}（含 master 账号密码）才能远程一键部署"
  fi
  [[ -f "${SCRIPT_DIR}/install-k8s-1.33.sh" ]] || err "找不到 ${SCRIPT_DIR}/install-k8s-1.33.sh"

  ensure_sshpass
  log "一键 VIP 部署目标："
  echo "  VIP=${vip}  peers=${peers}  lb_port=${lb_port}"
  echo "  配置: ${K8S_NODES_FILE}"
  echo

  local idx=0 ip host role user pass prio remote_dir remote_cmd
  remote_dir="/opt/service/k8s"
  while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    prio=$((100 - idx * 10))
    [[ "${prio}" -lt 50 ]] && prio=50
    idx=$((idx + 1))

    log "======== [${idx}] ${user}@${ip} (${host}) priority=${prio} ========"
    if [[ "${dry}" == "1" ]]; then
      echo "  DRY-RUN: vip --vip=${vip} --peers=${peers} --priority=${prio} --lb-port=${lb_port}${iface_arg:+ --iface=${iface_arg}}"
      continue
    fi

    if is_local_ip "${ip}"; then
      log "本机直接执行 vip"
      local args=(vip --vip="${vip}" --peers="${peers}" --priority="${prio}" --lb-port="${lb_port}")
      [[ -n "${iface_arg}" ]] && args+=(--iface="${iface_arg}")
      if bash "${SCRIPT_DIR}/install-k8s-1.33.sh" "${args[@]}"; then
        log "本机 VIP 配置成功"
      else
        warn "本机 VIP 配置失败"
      fi
      continue
    fi

    if [[ -z "${pass}" ]]; then
      if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "true" 2>/dev/null; then
        warn "跳过 ${ip}：无密码且无法免密 SSH，请先 ssh-keys 或填写 conf 密码"
        continue
      fi
    fi

    log "同步脚本与节点表到 ${ip}:${remote_dir}/"
    remote_ssh "${user}" "${ip}" "${pass}" "mkdir -p ${remote_dir}" || { warn "无法连接 ${ip}"; continue; }
    remote_scp "${user}" "${ip}" "${pass}" "${SCRIPT_DIR}/install-k8s-1.33.sh" "${remote_dir}/install-k8s-1.33.sh" \
      || { warn "scp 脚本失败 ${ip}"; continue; }
    remote_scp "${user}" "${ip}" "${pass}" "${K8S_NODES_FILE}" "${remote_dir}/k8s-nodes.conf" \
      || { warn "scp conf 失败 ${ip}"; continue; }

    remote_cmd="chmod +x ${remote_dir}/install-k8s-1.33.sh && cd ${remote_dir} && bash install-k8s-1.33.sh vip --vip=${vip} --peers=${peers} --priority=${prio} --lb-port=${lb_port}"
    [[ -n "${iface_arg}" ]] && remote_cmd+=" --iface=${iface_arg}"

    log "远程执行 vip（priority=${prio}）"
    if remote_ssh "${user}" "${ip}" "${pass}" "${remote_cmd}"; then
      log "OK ${host} (${ip}) priority=${prio}"
    else
      warn "FAIL ${host} (${ip}) — 可登录该机查看 journalctl -u keepalived"
    fi
    echo
  done < <(list_ssh_nodes | awk -F'|' 'tolower($3)=="master"')

  echo
  log "vip-all 结束。验证："
  echo "  ping -c2 ${vip}"
  echo "  各 Master: systemctl is-active keepalived haproxy ; ip -br a | grep ${vip}"
}

cmd_join() {
  need_root join
  [[ $# -ge 1 ]] || err "用法: $0 join <VIP>:${LB_PORT} --token ... --discovery-token-ca-cert-hash sha256:..."
  log "执行: kubeadm join $* --cri-socket unix:///run/containerd/containerd.sock"
  kubeadm join "$@" --cri-socket unix:///run/containerd/containerd.sock
  log "节点已加入集群"
}

ensure_cluster_admin() {
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  [[ -f "${KUBECONFIG}" ]] || err "请在已 init 的 Master 上执行（需要 ${KUBECONFIG}）"
  command -v kubectl >/dev/null 2>&1 || err "未找到 kubectl"
  command -v kubeadm >/dev/null 2>&1 || err "未找到 kubeadm"
  kubectl get nodes >/dev/null 2>&1 || err "无法访问集群 API，请确认本机 admin.conf 与 VIP/apiserver 可用"
}

# 判断节点是否已在集群（按主机名或 INTERNAL-IP）
node_in_cluster() {
  local ip="$1" host="$2"
  kubectl get nodes -o wide --no-headers 2>/dev/null | awk -v ip="${ip}" -v h="${host}" '
    {
      name=$1
      # NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL CONTAINER-RUNTIME
      internal=$6
      if (name == h || internal == ip) { found=1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

# 生成 worker join 参数（不含 kubeadm / cri-socket）：ENDPOINT --token ... --discovery-token-ca-cert-hash ...
build_join_worker_args() {
  local line token hash endpoint
  endpoint="$(default_vip_ip):${LB_PORT}"
  [[ "${endpoint}" != ":${LB_PORT}" ]] || err "节点表无 vip，无法构造 join 地址"
  line="$(kubeadm token create --print-join-command)"
  token="$(echo "${line}" | sed -n 's/.*--token \([^ ]*\).*/\1/p')"
  hash="$(echo "${line}" | sed -n 's/.*--discovery-token-ca-cert-hash \([^ ]*\).*/\1/p')"
  [[ -n "${token}" && -n "${hash}" ]] || err "解析 join 命令失败: ${line}"
  echo "${endpoint} --token ${token} --discovery-token-ca-cert-hash ${hash}"
}

# 上传控制面证书并返回 certificate-key
upload_certificate_key() {
  local out key
  out="$(kubeadm init phase upload-certs --upload-certs 2>&1)" || err "upload-certs 失败: ${out}"
  key="$(echo "${out}" | awk '
    /Using certificate key:/ { getline; gsub(/[[:space:]]/,""); if (length($0) >= 32) { print; exit } }
    /^[0-9a-fA-F]{64}$/ { print; exit }
  ')"
  [[ -n "${key}" ]] || err "未能解析 certificate-key，输出: ${out}"
  echo "${key}"
}

sync_install_to_node() {
  local user="$1" ip="$2" pass="$3" remote_dir="${4:-/opt/service/k8s}"
  remote_ssh "${user}" "${ip}" "${pass}" "mkdir -p ${remote_dir}" || return 1
  remote_scp "${user}" "${ip}" "${pass}" "${SCRIPT_DIR}/install-k8s-1.33.sh" "${remote_dir}/install-k8s-1.33.sh" || return 1
  if [[ -f "${K8S_NODES_FILE}" ]]; then
    remote_scp "${user}" "${ip}" "${pass}" "${K8S_NODES_FILE}" "${remote_dir}/k8s-nodes.conf" || return 1
  fi
  remote_ssh "${user}" "${ip}" "${pass}" "chmod +x ${remote_dir}/install-k8s-1.33.sh" || return 1
}

# 管理机一键：按 conf 把尚未入群的 worker 远程 join（自动建 token，无需手抄命令）
cmd_join_workers() {
  need_root join-workers
  local dry=0 do_prepare=0 only_ip=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry=1; shift ;;
      --prepare)  do_prepare=1; shift ;;
      --only=*)   only_ip="${1#*=}"; shift ;;
      *) err "用法: $0 join-workers [--prepare] [--only=IP] [--dry-run]" ;;
    esac
  done

  ensure_cluster_admin
  ensure_sshpass
  [[ -f "${SCRIPT_DIR}/install-k8s-1.33.sh" ]] || err "找不到安装脚本"

  local join_args
  join_args="$(build_join_worker_args)"
  log "自动生成 join 参数: ${join_args}"

  local ip host role user pass remote_dir remote_cmd n_ok=0 n_skip=0 n_fail=0
  remote_dir="/opt/service/k8s"
  while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    [[ -n "${only_ip}" && "${ip}" != "${only_ip}" ]] && continue

    log "======== worker ${user}@${ip} (${host}) ========"
    if node_in_cluster "${ip}" "${host}"; then
      log "已在集群，跳过"
      n_skip=$((n_skip + 1))
      continue
    fi

    if [[ "${dry}" == "1" ]]; then
      echo "  DRY-RUN: join ${join_args}${do_prepare:+ (+ prepare)}"
      continue
    fi

    if is_local_ip "${ip}"; then
      if [[ "${do_prepare}" == "1" ]]; then
        bash "${SCRIPT_DIR}/install-k8s-1.33.sh" prepare || warn "本机 prepare 失败，继续尝试 join"
      fi
      # shellcheck disable=SC2086
      if bash "${SCRIPT_DIR}/install-k8s-1.33.sh" join ${join_args}; then
        log "OK 本机 worker 已加入"
        n_ok=$((n_ok + 1))
      else
        warn "FAIL 本机 worker join"
        n_fail=$((n_fail + 1))
      fi
      continue
    fi

    if [[ -z "${pass}" ]] && ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "true" 2>/dev/null; then
      warn "跳过 ${ip}：无密码且无法免密 SSH"
      n_fail=$((n_fail + 1))
      continue
    fi

    sync_install_to_node "${user}" "${ip}" "${pass}" "${remote_dir}" || {
      warn "同步脚本失败 ${ip}"
      n_fail=$((n_fail + 1))
      continue
    }

    if [[ "${do_prepare}" == "1" ]]; then
      log "远程 prepare ${ip} ..."
      remote_ssh "${user}" "${ip}" "${pass}" "cd ${remote_dir} && bash install-k8s-1.33.sh prepare" \
        || warn "prepare 失败，仍尝试 join"
    fi

    remote_cmd="cd ${remote_dir} && bash install-k8s-1.33.sh join ${join_args}"
    log "远程 join worker"
    if remote_ssh "${user}" "${ip}" "${pass}" "${remote_cmd}"; then
      log "OK ${host} (${ip})"
      n_ok=$((n_ok + 1))
    else
      warn "FAIL ${host} (${ip})"
      n_fail=$((n_fail + 1))
    fi
    echo
  done < <(list_ssh_nodes | awk -F'|' 'tolower($3)=="worker"')

  echo
  log "join-workers 结束：成功=${n_ok} 跳过=${n_skip} 失败=${n_fail}"
  kubectl get nodes -o wide || true
}

# 管理机一键：按 conf 把尚未入群的 master 以 control-plane 远程 join
cmd_join_masters() {
  need_root join-masters
  local dry=0 do_prepare=0 do_vip=1 only_ip="" iface_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   dry=1; shift ;;
      --prepare)   do_prepare=1; shift ;;
      --no-vip)    do_vip=0; shift ;;
      --iface=*)   iface_arg="${1#*=}"; shift ;;
      --only=*)    only_ip="${1#*=}"; shift ;;
      *) err "用法: $0 join-masters [--prepare] [--no-vip] [--iface=网卡] [--only=IP] [--dry-run]" ;;
    esac
  done

  ensure_cluster_admin
  ensure_sshpass
  [[ -f "${SCRIPT_DIR}/install-k8s-1.33.sh" ]] || err "找不到安装脚本"

  local join_args cert_key
  join_args="$(build_join_worker_args)"
  cert_key="$(upload_certificate_key)"
  log "已 upload-certs，certificate-key 已生成（不打印全文）"
  log "join 基础参数: ${join_args}"

  if [[ "${do_vip}" == "1" && "${dry}" != "1" ]]; then
    log "先刷新全部 Master 的 HAProxy/Keepalived（vip-all）"
    if [[ -n "${iface_arg}" ]]; then
      cmd_vip_all --iface="${iface_arg}" || warn "vip-all 有失败，仍继续 join"
    else
      cmd_vip_all || warn "vip-all 有失败，仍继续 join"
    fi
  fi

  local ip host role user pass remote_dir remote_cmd n_ok=0 n_skip=0 n_fail=0
  remote_dir="/opt/service/k8s"
  while IFS='|' read -r ip host role user pass; do
    [[ -n "${ip}" ]] || continue
    [[ -n "${only_ip}" && "${ip}" != "${only_ip}" ]] && continue

    log "======== master ${user}@${ip} (${host}) ========"
    if node_in_cluster "${ip}" "${host}"; then
      log "已在集群，跳过"
      n_skip=$((n_skip + 1))
      continue
    fi

    local cp_extra="--control-plane --certificate-key ${cert_key} --apiserver-advertise-address=${ip}"
    if [[ "${dry}" == "1" ]]; then
      echo "  DRY-RUN: join ${join_args} ${cp_extra}${do_prepare:+ (+ prepare)}${do_vip:+ (+ vip-all)}"
      continue
    fi

    if is_local_ip "${ip}"; then
      if [[ "${do_prepare}" == "1" ]]; then
        bash "${SCRIPT_DIR}/install-k8s-1.33.sh" prepare || warn "本机 prepare 失败"
      fi
      # shellcheck disable=SC2086
      if bash "${SCRIPT_DIR}/install-k8s-1.33.sh" join ${join_args} ${cp_extra}; then
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config 2>/dev/null || true
        log "OK 本机 master 已加入"
        n_ok=$((n_ok + 1))
      else
        warn "FAIL 本机 master join"
        n_fail=$((n_fail + 1))
      fi
      continue
    fi

    if [[ -z "${pass}" ]] && ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${ip}" "true" 2>/dev/null; then
      warn "跳过 ${ip}：无密码且无法免密 SSH"
      n_fail=$((n_fail + 1))
      continue
    fi

    sync_install_to_node "${user}" "${ip}" "${pass}" "${remote_dir}" || {
      warn "同步脚本失败 ${ip}"
      n_fail=$((n_fail + 1))
      continue
    }

    if [[ "${do_prepare}" == "1" ]]; then
      log "远程 prepare ${ip} ..."
      remote_ssh "${user}" "${ip}" "${pass}" "cd ${remote_dir} && bash install-k8s-1.33.sh prepare" \
        || warn "prepare 失败，仍尝试 join"
    fi

    remote_cmd="cd ${remote_dir} && bash install-k8s-1.33.sh join ${join_args} ${cp_extra}"
    log "远程 join control-plane"
    if remote_ssh "${user}" "${ip}" "${pass}" "${remote_cmd}"; then
      remote_ssh "${user}" "${ip}" "${pass}" \
        "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chmod 600 /root/.kube/config" \
        || true
      log "OK ${host} (${ip})"
      n_ok=$((n_ok + 1))
    else
      warn "FAIL ${host} (${ip}) — 证书密钥约 2 小时有效，失败可重跑本命令"
      n_fail=$((n_fail + 1))
    fi
    echo
  done < <(list_ssh_nodes | awk -F'|' 'tolower($3)=="master"')

  echo
  log "join-masters 结束：成功=${n_ok} 跳过=${n_skip} 失败=${n_fail}"
  kubectl get nodes -o wide || true
}

# 一键：先补 Master，再补 Worker
cmd_join_all() {
  need_root join-all
  local rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workers-only)
        shift
        cmd_join_workers "$@"
        return
        ;;
      --masters-only)
        shift
        cmd_join_masters "$@"
        return
        ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  log "==== 1/2 join-masters ===="
  cmd_join_masters "${rest[@]}"
  log "==== 2/2 join-workers ===="
  # workers 不需要 vip / cert；过滤掉 master 专用参数
  local wargs=()
  local a
  for a in "${rest[@]}"; do
    case "${a}" in
      --no-vip|--iface=*) ;;
      *) wargs+=("${a}") ;;
    esac
  done
  cmd_join_workers "${wargs[@]}"
}

cmd_cni_flannel() {
  need_root cni-flannel
  export KUBECONFIG=/etc/kubernetes/admin.conf
  local raw url tmp
  raw="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
  url="$(gh_url "${raw}")"
  tmp="$(mktemp)"
  log "安装 Flannel（yaml: ${url}）"
  curl -fsSL "${url}" -o "${tmp}" || err "下载 Flannel yaml 失败，可设置 GH_PROXY 或手动下载后 kubectl apply"
  # 替换镜像为国内可访问地址
  sed -i \
    -e "s|docker.io/flannel/|${FLANNEL_IMAGE_REPO}/|g" \
    -e "s|ghcr.io/flannel-io/|${FLANNEL_IMAGE_REPO}/|g" \
    "${tmp}" || true
  kubectl apply -f "${tmp}"
  rm -f "${tmp}"
  kubectl get pods -A | grep -i flannel || kubectl get pods -A
}

cmd_cni_calico() {
  need_root cni-calico
  export KUBECONFIG=/etc/kubernetes/admin.conf
  local op_raw cr_raw
  op_raw="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/tigera-operator.yaml"
  cr_raw="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/custom-resources.yaml"
  log "安装 Calico（经 GitHub 代理: ${GH_PROXY:-直连}）"
  kubectl create -f "$(gh_url "${op_raw}")"
  curl -fsSL "$(gh_url "${cr_raw}")" \
    | sed "s|cidr: 192\.168\.0\.0/16|cidr: ${POD_CIDR}|" \
    | kubectl apply -f -
  warn "Calico operator 镜像若仍超时，请在官方文档配置 imagePath / registry 为国内仓库"
  kubectl get pods -A | head -50
}

cmd_status() {
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  if [[ ! -f "${KUBECONFIG}" ]]; then
    err "未找到 ${KUBECONFIG}，请在控制面执行或 export KUBECONFIG=..."
  fi
  kubectl get nodes -o wide
  kubectl get pods -A
}

cmd_reset() {
  need_root reset
  warn "将重置本机 kubeadm / 容器网络，5 秒后继续... Ctrl+C 取消"
  sleep 5
  kubeadm reset -f || true
  rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet/* || true
  iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
  ipvsadm -C 2>/dev/null || true
  systemctl restart containerd || true
  log "已 reset。可再执行: sudo bash $0 prepare"
}

usage() {
  cat <<EOF
Ubuntu 24 + Kubernetes ${K8S_MINOR}（kubeadm，默认国内镜像，可配置多节点）

用法:
  sudo bash $0 prepare
  sudo bash $0 hosts | nodes | ssh-keys
  sudo bash $0 vip [--iface=网卡] [--priority=100]   # 仅本机
  sudo bash $0 vip-all [--iface=网卡]              # 管理机一键部署全部 Master（读 conf）
  sudo bash $0 init --apiserver-advertise-address=<本机IP> --control-plane-endpoint=<VIP:8443>
  sudo bash $0 cni-calico                                      # 默认网络插件（也可 cni-flannel）
  sudo bash $0 join <VIP>:8443 --token ... --discovery-token-ca-cert-hash sha256:...
  sudo bash $0 join-masters [--prepare] [--no-vip] [--only=IP]   # 管理机一键加 Master（自动 token/证书）
  sudo bash $0 join-workers [--prepare] [--only=IP]            # 管理机一键加 Worker
  sudo bash $0 join-all [--prepare]                            # 先 Master 后 Worker
  sudo bash $0 status | reset

节点表（增删改只改表，然后 hosts + vip + join）:
  文件: ${K8S_NODES_FILE}
  格式: IP|主机名|角色|用户|密码   角色=vip|master|worker
  查看: bash $0 nodes

国内镜像: K8S_APT_MIRROR / IMAGE_REPOSITORY / PAUSE_IMAGE / DOCKER_MIRROR / GH_PROXY

EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    prepare)     cmd_prepare "$@" ;;
    hosts)       cmd_hosts "$@" ;;
    nodes)       cmd_nodes "$@" ;;
    ssh-keys)    cmd_ssh_keys "$@" ;;
    vip)         cmd_vip "$@" ;;
    vip-all)     cmd_vip_all "$@" ;;
    init)        cmd_init "$@" ;;
    join)         cmd_join "$@" ;;
    join-workers) cmd_join_workers "$@" ;;
    join-masters) cmd_join_masters "$@" ;;
    join-all)     cmd_join_all "$@" ;;
    cni-flannel)  cmd_cni_flannel "$@" ;;
    cni-calico)  cmd_cni_calico "$@" ;;
    status)      cmd_status "$@" ;;
    reset)       cmd_reset "$@" ;;
    -h|--help|help|"") usage ;;
    *) err "未知命令: ${cmd}（--help 查看用法）" ;;
  esac
}

main "$@"
