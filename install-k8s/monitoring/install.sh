#!/usr/bin/env bash
# 从 config.yaml 删除/安装整套监控（串行、低并发，避免 etcd 超时）
# 用法：
#   bash install.sh            # 安装/升级
#   bash install.sh destroy    # 仅删除
#   bash install.sh reinstall  # 全部删除后重建
set -euo pipefail

NS=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
CFG="${DIR}/config.yaml"
TMP="${DIR}/.generated"
mkdir -p "$TMP"

NODE_EXPORTER_IMAGE="registry.cn-chengdu.aliyuncs.com/obsbot/node-exporter:v1.8.2"
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
    "registry": "registry.cn-chengdu.aliyuncs.com",
    "repository": "obsbot/node-exporter",
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
  gen

  echo "======== 安装监控（低并发串行）========"
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
      --set prometheus-node-exporter.image.registry=registry.cn-chengdu.aliyuncs.com \
      --set prometheus-node-exporter.image.repository=obsbot/node-exporter \
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
        --set prometheus-node-exporter.image.registry=registry.cn-chengdu.aliyuncs.com \
        --set prometheus-node-exporter.image.repository=obsbot/node-exporter \
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
  reinstall)
    destroy
    pause 60
    install_all
    ;;
  install|upgrade|"")
    install_all
    ;;
  *)
    echo "用法: bash install.sh [install|reinstall|destroy]"
    exit 1
    ;;
esac
