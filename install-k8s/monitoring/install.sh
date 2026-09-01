#!/usr/bin/env bash
# 从 config.yaml 删除/安装整套监控（串行、低并发，避免 etcd 超时）
# 用法：
#   bash install.sh            # 预拉镜像后安装/升级
#   bash install.sh images     # 只打印并预下载镜像
#   bash install.sh destroy    # 仅删除
#   bash install.sh reinstall  # 全部删除后重建
# 跳过预拉: SKIP_IMAGE_PULL=1 bash install.sh
set -euo pipefail

NS=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
export DIR
CFG="${DIR}/config.yaml"
TMP="${DIR}/.generated"
mkdir -p "$TMP"

NODE_EXPORTER_IMAGE="registry.cn-global.starbucket.com.cn/starbucket/docker.io/prom/node-exporter:v1.8.2"
LOKI_PVC="storage-loki-0"
LOKI_PV="pv-mon-loki"

# 节奏控制（可按机器调整）
SLEEP_SHORT=3
SLEEP_STEP=15
SLEEP_HELM=45
HELM_RETRIES=6
HELM_RETRY_WAIT=40

need_py() {
  python3 - <<'PY'
import sys
try:
  import yaml
except ImportError:
  sys.exit(1)
PY
}

if ! need_py; then
  echo "需要 PyYAML: pip3 install pyyaml  或  apt-get install -y python3-yaml"
  exit 1
fi

log() { echo ">>> $*"; }
pause() { local s="${1:-$SLEEP_STEP}"; log "等待 ${s}s（降低 API 压力）..."; sleep "$s"; }

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o BatchMode=yes
  -o ConnectTimeout=8
)

K8S_NODES_FILE="${K8S_NODES_FILE:-${DIR}/../k8s-nodes.conf}"

# 从 config.yaml 收集实际会拉起的镜像（跳过已关闭的 init / sidecar）
list_images() {
  python3 - <<'PY'
import os, yaml

cfg_path = os.path.join(os.environ.get("DIR", "."), "config.yaml")
with open(cfg_path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

kp = cfg.get("kubePrometheus") or {}
g = kp.get("grafana") or {}
ic = g.get("initChownData") or {}
if not ic.get("enabled"):
    ic.pop("image", None)
loki = cfg.get("loki") or {}
sc = loki.get("sidecar") or {}
if not (sc.get("rules") or {}).get("enabled"):
    sc.pop("image", None)
if not (loki.get("gateway") or {}).get("enabled"):
    (loki.get("gateway") or {}).pop("image", None)

def collect(obj, out):
    if isinstance(obj, dict):
        repo = obj.get("repository")
        if isinstance(repo, str) and repo.strip() and (
            obj.get("registry") or obj.get("tag") is not None or obj.get("digest")
        ):
            registry = str(obj.get("registry") or "").strip().rstrip("/")
            tag = str(obj.get("tag") or "").strip()
            digest = str(obj.get("digest") or "").strip()
            path = f"{registry}/{repo}" if registry else repo
            if digest:
                out.append(f"{path}@{digest}" if not tag else f"{path}:{tag}")
            elif tag:
                out.append(f"{path}:{tag}")
        for v in obj.values():
            collect(v, out)
    elif isinstance(obj, list):
        for i in obj:
            collect(i, out)

seen, images = set(), []
acc = []
collect(cfg, acc)
for img in acc:
    if img not in seen:
        seen.add(img)
        images.append(img)
for img in images:
    print(img)
PY
}

pull_one_image() {
  local img="$1"
  if command -v crictl >/dev/null 2>&1; then
    crictl pull "$img"
  elif command -v ctr >/dev/null 2>&1; then
    ctr -n k8s.io images pull "$img"
  elif command -v nerdctl >/dev/null 2>&1; then
    nerdctl pull "$img"
  elif command -v docker >/dev/null 2>&1; then
    docker pull "$img"
  else
    echo "错误: 需要 crictl / ctr / nerdctl / docker 之一才能预拉镜像"
    return 1
  fi
}

conf_node_ips() {
  local f="$K8S_NODES_FILE"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "${line:-}" ]; do
    line="${line%%#*}"
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    IFS='|' read -r ip _ role _ _ <<<"$line"
    ip="${ip// /}"
    role="${role// /}"
    [[ "$role" == "master" || "$role" == "worker" ]] || continue
    [ -n "$ip" ] && echo "$ip"
  done < "$f"
}

is_local_ip() {
  local ip="$1" x
  [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && return 0
  for x in $(hostname -I 2>/dev/null || true); do
    [ "$x" = "$ip" ] && return 0
  done
  return 1
}

prefetch_images() {
  local imgs=() img i n ip ok fail
  log "所需镜像（来自 config.yaml）"
  while IFS= read -r img; do
    [ -n "$img" ] && imgs+=("$img")
  done < <(list_images)
  if [ "${#imgs[@]}" -eq 0 ]; then
    echo "错误: 未从 config.yaml 解析到镜像"
    exit 1
  fi
  mkdir -p "$TMP"
  printf '%s\n' "${imgs[@]}" > "${TMP}/images.txt"
  echo "  共 ${#imgs[@]} 个："
  echo "  ----------------------------------------"
  i=0
  for img in "${imgs[@]}"; do
    i=$((i + 1))
    printf "  %2d. %s\n" "$i" "$img"
  done
  echo "  ----------------------------------------"

  if [ "${SKIP_IMAGE_PULL:-0}" = "1" ]; then
    log "SKIP_IMAGE_PULL=1，跳过预下载"
    return 0
  fi

  log "本机预下载镜像"
  i=0
  for img in "${imgs[@]}"; do
    i=$((i + 1))
    log "pull [${i}/${#imgs[@]}] ${img}"
    if ! pull_one_image "$img"; then
      echo "错误: 本机拉取失败: ${img}"
      exit 1
    fi
  done
  log "本机预下载完成"

  n=0
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    is_local_ip "$ip" && continue
    n=$((n + 1))
  done < <(conf_node_ips)

  if [ "$n" -eq 0 ]; then
    log "未从 ${K8S_NODES_FILE} 解析到其它节点；DaemonSet（node-exporter / Promtail）请在各节点自行 crictl pull"
    return 0
  fi

  log "按 k8s-nodes.conf 在其它节点预下载（免密 SSH）"
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    is_local_ip "$ip" && continue
    log "节点 ${ip}"
    ok=0
    fail=0
    for img in "${imgs[@]}"; do
      if ssh -n "${SSH_OPTS[@]}" \
        "root@${ip}" "command -v crictl >/dev/null && crictl pull '$img' || ctr -n k8s.io images pull '$img'"; then
        ok=$((ok + 1))
      else
        echo "    失败: ${img}"
        fail=$((fail + 1))
      fi
    done
    if [ "$fail" -gt 0 ]; then
      echo "警告: ${ip} 有 ${fail} 个镜像未拉成功（已成功 ${ok}）"
    else
      log "${ip} 完成（${ok}）"
    fi
  done < <(conf_node_ips)
}

wait_api() {
  log "检查 API / etcd 是否可用"
  for i in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1 && kubectl get ns >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  echo "警告: API 仍不稳定，继续尝试（可能再次超时）"
}

# 串行删除一类资源，避免一次性打爆 etcd
delete_each() {
  local kind="$1"
  local names
  names=$(kubectl -n "$NS" get "$kind" -o name 2>/dev/null || true)
  [ -z "$names" ] && return 0
  while IFS= read -r obj; do
    [ -z "$obj" ] && continue
    kubectl -n "$NS" delete "$obj" --wait=false --ignore-not-found 2>/dev/null || true
    sleep "$SLEEP_SHORT"
  done <<< "$names"
}

helm_retry() {
  local desc="$1"
  shift
  local i
  for i in $(seq 1 "$HELM_RETRIES"); do
    wait_api
    log "${desc}（第 ${i}/${HELM_RETRIES} 次）"
    if "$@"; then
      log "${desc} 成功"
      pause "$SLEEP_HELM"
      return 0
    fi
    echo "    失败，${HELM_RETRY_WAIT}s 后重试..."
    sleep "$HELM_RETRY_WAIT"
  done
  echo "错误: ${desc} 重试 ${HELM_RETRIES} 次仍失败"
  return 1
}

# 先单独、缓慢安装 CRD，减轻后续 helm 压力
install_prometheus_crds() {
  log "预装 kube-prometheus-stack CRD（串行 apply）"
  local crd_dir="${TMP}/kube-prom-chart"
  rm -rf "$crd_dir"
  mkdir -p "$crd_dir"
  (
    cd "$crd_dir"
    helm pull prometheus-community/kube-prometheus-stack --untar 2>/dev/null \
      || helm pull prometheus-community/kube-prometheus-stack --untar
  )
  local f
  # charts 目录结构: kube-prometheus-stack/charts/... 或 kube-prometheus-stack/crds
  local crds_path
  crds_path=$(find "$crd_dir" -type d -name crds | head -1 || true)
  if [ -z "${crds_path:-}" ]; then
    log "未找到 CRD 目录，跳过预装（由 helm 安装时创建）"
    return 0
  fi
  for f in "$crds_path"/*.yaml; do
    [ -f "$f" ] || continue
    wait_api
    log "apply CRD: $(basename "$f")"
    kubectl apply --server-side --force-conflicts -f "$f" 2>/dev/null \
      || kubectl apply -f "$f" || true
    sleep "$SLEEP_SHORT"
  done
  pause "$SLEEP_STEP"
}

gen() {
  export DIR
  python3 - <<'PY'
import os, yaml
base = os.environ.get("DIR", ".")
cfg_path = os.path.join(base, "config.yaml")
tmp = os.path.join(base, ".generated")
os.makedirs(tmp, exist_ok=True)
with open(cfg_path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

nfs = cfg["nfs"]
server = nfs["server"]
base_path = nfs["basePath"].rstrip("/")

# 拆成多个小文件，串行 apply
parts = {
  "00-ns.yaml": f"""apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
""",
  "01-pv-grafana.yaml": f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mon-grafana
spec:
  capacity:
    storage: 10Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600"]
  nfs:
    server: {server}
    path: {base_path}/grafana
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-grafana
  namespace: monitoring
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: pv-mon-grafana
  resources:
    requests:
      storage: 10Gi
""",
  "02-pv-prometheus.yaml": f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mon-prometheus
spec:
  capacity:
    storage: 50Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600"]
  nfs:
    server: {server}
    path: {base_path}/prometheus
""",
  "03-pv-alertmanager.yaml": f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mon-alertmanager
spec:
  capacity:
    storage: 5Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600"]
  nfs:
    server: {server}
    path: {base_path}/alertmanager
""",
  "04-pv-loki.yaml": f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mon-loki
spec:
  capacity:
    storage: 50Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600"]
  nfs:
    server: {server}
    path: {base_path}/loki
""",
}

for name, content in parts.items():
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        f.write(content)

with open(os.path.join(tmp, "loki-pvc.yaml"), "w", encoding="utf-8") as f:
    f.write(f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-loki-0
  namespace: monitoring
  labels:
    app.kubernetes.io/name: loki
    app.kubernetes.io/instance: loki
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: pv-mon-loki
  resources:
    requests:
      storage: 50Gi
""")

kp = cfg["kubePrometheus"]
kp.setdefault("prometheus-node-exporter", {})
kp["prometheus-node-exporter"]["enabled"] = True
kp["prometheus-node-exporter"]["image"] = {
    "registry": "registry.cn-global.starbucket.com.cn/starbucket",
    "repository": "docker.io/prom/node-exporter",
    "tag": "v1.8.2",
    "digest": "",
    "pullPolicy": "IfNotPresent",
}

loki = cfg["loki"]
loki.setdefault("singleBinary", {})["replicas"] = 0

for name, data in [
    ("kube-prometheus.yaml", kp),
    ("loki.yaml", loki),
    ("promtail.yaml", cfg["promtail"]),
]:
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)

print("generated:", tmp)
print("NFS 目录权限（在 {server} 执行）:".format(server=server))
print(f"  mkdir -p {base_path}/{{prometheus,grafana,alertmanager,loki}}")
print(f"  chown -R 472:472 {base_path}/grafana")
print(f"  chown -R 1000:2000 {base_path}/prometheus")
print(f"  chown -R 1000:2000 {base_path}/alertmanager")
print(f"  chown -R 10001:10001 {base_path}/loki")
PY
}

apply_nfs_slow() {
  log "串行应用 NFS 清单"
  local f
  for f in "$TMP"/0*.yaml; do
    [ -f "$f" ] || continue
    wait_api
    log "apply $(basename "$f")"
    kubectl apply -f "$f"
    sleep "$SLEEP_SHORT"
  done
  pause "$SLEEP_STEP"
  kubectl -n "$NS" get pvc 2>/dev/null || true
  kubectl get pv | grep pv-mon || true
}

wait_ns_gone() {
  log "等待 Namespace 消失..."
  for i in $(seq 1 90); do
    if ! kubectl get ns "$NS" >/dev/null 2>&1; then
      log "Namespace 已删除"
      return 0
    fi
    if [ $((i % 5)) -eq 0 ]; then
      kubectl get ns "$NS" -o json 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);d['spec']['finalizers']=[];print(json.dumps(d))" 2>/dev/null \
        | kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f - 2>/dev/null || true
    fi
    sleep 2
  done
  echo "警告: Namespace 可能仍在 Terminating"
}

destroy() {
  echo "======== 删除全部监控（串行）========"
  wait_api

  log "缩容 Loki"
  kubectl -n "$NS" scale sts loki --replicas=0 2>/dev/null || true
  pause "$SLEEP_STEP"

  log "卸载 Helm（逐个）"
  wait_api
  helm -n "$NS" uninstall promtail 2>/dev/null || true
  pause "$SLEEP_STEP"
  wait_api
  helm -n "$NS" uninstall loki 2>/dev/null || true
  pause "$SLEEP_STEP"
  wait_api
  helm -n "$NS" uninstall kube-prometheus 2>/dev/null || true
  pause "$SLEEP_HELM"

  log "串行删除工作负载"
  delete_each sts
  delete_each deploy
  delete_each ds
  delete_each job
  pause "$SLEEP_STEP"

  log "串行删除 Prometheus CR"
  delete_each prometheus
  delete_each alertmanager
  delete_each servicemonitor
  delete_each podmonitor
  delete_each prometheusrule
  pause "$SLEEP_STEP"

  log "串行删除 PVC / Pod"
  delete_each pvc
  delete_each pod
  pause "$SLEEP_STEP"

  log "删除 Namespace"
  kubectl delete ns "$NS" --wait=false --ignore-not-found
  sleep 5
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl get ns "$NS" -o json \
      | python3 -c "import sys,json;d=json.load(sys.stdin);d['spec']['finalizers']=[];print(json.dumps(d))" \
      | kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f - 2>/dev/null || true
  fi

  log "串行删除 PV"
  for pv in pv-mon-grafana pv-mon-prometheus pv-mon-alertmanager pv-mon-loki; do
    kubectl patch pv "$pv" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    sleep 1
    kubectl delete pv "$pv" --ignore-not-found --wait=false 2>/dev/null || true
    sleep "$SLEEP_SHORT"
  done

  wait_ns_gone

  for pv in pv-mon-grafana pv-mon-prometheus pv-mon-alertmanager pv-mon-loki; do
    kubectl patch pv "$pv" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    kubectl delete pv "$pv" --ignore-not-found --wait=false 2>/dev/null || true
    sleep 1
  done

  pause "$SLEEP_HELM"
  log "删除完成"
}

ensure_loki_pvc() {
  log "校正 Loki PVC (${LOKI_PVC})"
  kubectl -n "$NS" scale sts loki --replicas=0 2>/dev/null || true
  pause "$SLEEP_STEP"

  kubectl -n "$NS" delete pvc "$LOKI_PVC" --ignore-not-found --wait=false 2>/dev/null || true
  sleep "$SLEEP_SHORT"
  kubectl patch pv "$LOKI_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true

  for i in $(seq 1 40); do
    kubectl -n "$NS" get pvc "$LOKI_PVC" >/dev/null 2>&1 || break
    sleep 1
  done
  for i in $(seq 1 40); do
    st=$(kubectl get pv "$LOKI_PV" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)
    [ "$st" = "Available" ] && break
    if [ "$st" = "Released" ] || [ "$st" = "Bound" ]; then
      kubectl patch pv "$LOKI_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    fi
    sleep 1
  done

  wait_api
  kubectl create -f "$TMP/loki-pvc.yaml"
  for i in $(seq 1 40); do
    phase=$(kubectl -n "$NS" get pvc "$LOKI_PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Bound" ] && break
    sleep 1
  done

  kubectl -n "$NS" get pvc "$LOKI_PVC"
  phase=$(kubectl -n "$NS" get pvc "$LOKI_PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" != "Bound" ]; then
    echo "错误: ${LOKI_PVC} 未 Bound"
    kubectl -n "$NS" describe pvc "$LOKI_PVC" | tail -30 || true
    exit 1
  fi
  pause "$SLEEP_STEP"
}

fix_node_exporter() {
  log "校正 node-exporter 镜像"
  for i in $(seq 1 40); do
    DS=$(kubectl -n "$NS" get ds -o name 2>/dev/null | grep -i node-exporter | head -1 || true)
    [ -n "${DS:-}" ] && break
    sleep 3
  done
  if [ -n "${DS:-}" ]; then
    CNAME=$(kubectl -n "$NS" get "$DS" -o jsonpath='{.spec.template.spec.containers[0].name}')
    kubectl -n "$NS" set image "$DS" "${CNAME}=${NODE_EXPORTER_IMAGE}"
    sleep "$SLEEP_SHORT"
    kubectl -n "$NS" patch "$DS" --type='json' -p="[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${NODE_EXPORTER_IMAGE}\"}
    ]"
    # 滚动删除，避免一次删光所有节点 Pod
    for p in $(kubectl -n "$NS" get pod -l app.kubernetes.io/name=prometheus-node-exporter -o name 2>/dev/null); do
      kubectl -n "$NS" delete "$p" --wait=false --ignore-not-found 2>/dev/null || true
      sleep "$SLEEP_SHORT"
    done
    log "node-exporter => ${NODE_EXPORTER_IMAGE}"
  else
    echo "警告: 未找到 node-exporter DaemonSet"
  fi
  pause "$SLEEP_STEP"
}

install_all() {
  export DIR
  echo "======== 安装监控（低并发串行）========"
  prefetch_images
  gen
  wait_api
  apply_nfs_slow

  log "更新 Helm 仓库"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  sleep 2
  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  sleep 2
  helm repo update
  pause "$SLEEP_STEP"

  install_prometheus_crds

  # 优先 skip-crds（CRD 已串行预装）；失败再完整安装
  set +e
  helm_retry "安装 kube-prometheus-stack(skip-crds)" \
    helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
      -n "$NS" \
      -f "$TMP/kube-prometheus.yaml" \
      --set prometheus-node-exporter.image.registry=registry.cn-global.starbucket.com.cn/starbucket \
      --set prometheus-node-exporter.image.repository=docker.io/prom/node-exporter \
      --set prometheus-node-exporter.image.tag=v1.8.2 \
      --set prometheus-node-exporter.image.digest="" \
      --timeout 45m \
      --wait=false \
      --skip-crds
  kp_ok=$?
  set -e

  if [ "$kp_ok" -ne 0 ] || ! helm -n "$NS" status kube-prometheus >/dev/null 2>&1; then
    log "改为完整安装 kube-prometheus-stack（含 CRD）"
    helm_retry "安装 kube-prometheus-stack(含CRD)" \
      helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
        -n "$NS" \
        -f "$TMP/kube-prometheus.yaml" \
        --set prometheus-node-exporter.image.registry=registry.cn-global.starbucket.com.cn/starbucket \
        --set prometheus-node-exporter.image.repository=docker.io/prom/node-exporter \
        --set prometheus-node-exporter.image.tag=v1.8.2 \
        --set prometheus-node-exporter.image.digest="" \
        --timeout 45m \
        --wait=false
  fi

  pause 60
  fix_node_exporter

  helm_retry "安装 Loki(replicas=0)" \
    helm upgrade --install loki grafana/loki \
      -n "$NS" \
      -f "$TMP/loki.yaml" \
      --set singleBinary.replicas=0 \
      --timeout 30m \
      --wait=false

  for i in $(seq 1 40); do
    kubectl -n "$NS" get sts loki >/dev/null 2>&1 && break
    sleep 3
  done

  ensure_loki_pvc

  log "拉起 Loki replicas=1"
  kubectl -n "$NS" scale sts loki --replicas=1
  pause "$SLEEP_STEP"

  helm_retry "同步 Loki(replicas=1)" \
    helm upgrade loki grafana/loki \
      -n "$NS" \
      -f "$TMP/loki.yaml" \
      --set singleBinary.replicas=1 \
      --timeout 30m \
      --wait=false

  helm_retry "安装 Promtail" \
    helm upgrade --install promtail grafana/promtail \
      -n "$NS" \
      -f "$TMP/promtail.yaml" \
      --timeout 30m \
      --wait=false

  echo "======== 状态 ========"
  pause "$SLEEP_STEP"
  kubectl -n "$NS" get pod,pvc
  kubectl get pv | grep pv-mon || true
  helm -n "$NS" list
  echo ""
  echo "Grafana:      http://<节点IP>:30300  admin / admin123456"
  echo "Prometheus:   http://<节点IP>:30390"
  echo "Alertmanager: http://<节点IP>:30303"
  echo "日志: Grafana → Explore → Loki"
}

cmd="${1:-install}"
case "$cmd" in
  destroy|uninstall|delete)
    destroy
    ;;
  images|pull|prefetch)
    export DIR
    prefetch_images
    ;;
  reinstall)
    destroy
    pause 60
    install_all
    ;;
  install|upgrade|"")
    install_all
    ;;
  *)
    echo "用法: bash install.sh [install|images|reinstall|destroy]"
    exit 1
    ;;
esac
