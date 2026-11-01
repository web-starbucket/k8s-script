#!/usr/bin/env bash
# 从 config.yaml 删除/安装整套监控（串行、低并发，避免 etcd 超时）
# 用法：
#   bash install.sh            # 预拉镜像后安装/升级
#   bash install.sh images     # 只打印并预下载镜像
#   bash install.sh destroy    # 仅删除
#   bash install.sh reinstall  # 全部删除后重建
# 跳过预拉: SKIP_IMAGE_PULL=1 bash install.sh
# 存储后端: config.yaml 的 storage.type（nfs=静态 PV；ceph-rbd=动态供给，需先装 install-ceph 的 CSI）
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
TEMPO_PVC="storage-tempo-0"
TEMPO_PV="pv-mon-tempo"

# 存储后端（config.yaml: storage.type / storage.storageClass）
read -r STORAGE_TYPE STORAGE_CLASS < <(python3 - <<'PY'
import os, yaml
cfg = yaml.safe_load(open(os.path.join(os.environ.get("DIR", "."), "config.yaml"), encoding="utf-8"))
s = cfg.get("storage") or {}
t = str(s.get("type") or "nfs").strip().lower()
sc = str(s.get("storageClass") or "ceph-rbd").strip()
print(t or "nfs", sc or "ceph-rbd")
PY
)
STORAGE_TYPE="${STORAGE_TYPE:-nfs}"
STORAGE_CLASS="${STORAGE_CLASS:-ceph-rbd}"

# kube-prometheus-stack chart 钉版（appVersion=operator v0.77.2，与 config.yaml 镜像钉版对应；
# 升级时整套一起升：chart + operator/CRD/相关镜像）
KPS_CHART_VERSION="${KPS_CHART_VERSION:-65.8.1}"

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
  local filter="${1:-}" imgs=() img i n ip ok fail
  log "所需镜像（来自 config.yaml）"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    if [ -n "$filter" ]; then
      case "$img" in
        *"$filter"*) ;;
        *) continue ;;
      esac
    fi
    imgs+=("$img")
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
    log "未从 ${K8S_NODES_FILE} 解析到其它节点；DaemonSet（node-exporter / Alloy）请在各节点自行 crictl pull"
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

# 先单独安装 Prometheus Operator CRD，并等到 Established
install_prometheus_crds() {
  log "预装 kube-prometheus-stack CRD"
  local crd_dir="${TMP}/kube-prom-chart"
  rm -rf "$crd_dir"
  mkdir -p "$crd_dir"
  (
    cd "$crd_dir"
    helm pull prometheus-community/kube-prometheus-stack --version "$KPS_CHART_VERSION" --untar 2>/dev/null \
      || helm pull prometheus-community/kube-prometheus-stack --version "$KPS_CHART_VERSION" --untar
  )

  # 新版 chart 结构：纯 CRD 在 charts/crds/crds/crd-*.yaml。
  # 按内容筛（kind: CustomResourceDefinition 且无 helm 模板语法），避免误 apply values.yaml
  local f n=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -q '^kind: CustomResourceDefinition' "$f" 2>/dev/null || continue
    grep -q '{{' "$f" 2>/dev/null && continue
    n=$((n + 1))
    wait_api
    log "apply CRD: $(basename "$f")"
    kubectl apply --server-side --force-conflicts -f "$f" \
      || kubectl apply -f "$f"
    sleep 1
  done < <(find "$crd_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) \
    | grep -viE '/tests/|/templates/|/ci/' \
    | sort \
    || true)

  if [ "$n" -eq 0 ]; then
    echo "警告: chart 内未找到 CRD 文件，尝试从 GitHub 拉取 prometheus-operator CRD"
    local gh="${GH_PROXY:-https://ghfast.top/}"
    [[ "${gh}" == */ ]] || gh="${gh}/"
    local url="${gh}https://github.com/prometheus-operator/prometheus-operator/releases/latest/download/stripped-down-crds.yaml"
    if ! curl -fL --connect-timeout 20 -o "${TMP}/prom-crds.yaml" "$url"; then
      url="${gh}https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"
      mkdir -p "${TMP}/prom-crds"
      curl -fL --connect-timeout 20 -o "${TMP}/prom-crds/servicemonitors.yaml" "$url" \
        || { echo "错误: 无法下载 ServiceMonitor CRD"; return 1; }
      kubectl apply --server-side --force-conflicts -f "${TMP}/prom-crds/servicemonitors.yaml"
    else
      kubectl apply --server-side --force-conflicts -f "${TMP}/prom-crds.yaml"
    fi
  fi

  log "等待 ServiceMonitor 等 CRD Established"
  local crd
  for crd in \
    servicemonitors.monitoring.coreos.com \
    podmonitors.monitoring.coreos.com \
    probes.monitoring.coreos.com \
    prometheuses.monitoring.coreos.com \
    alertmanagers.monitoring.coreos.com \
    prometheusagents.monitoring.coreos.com \
    scrapeconfigs.monitoring.coreos.com \
    thanosrulers.monitoring.coreos.com \
    alertmanagerconfigs.monitoring.coreos.com \
    prometheusrules.monitoring.coreos.com; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      kubectl wait --for=condition=Established "crd/${crd}" --timeout=120s \
        || echo "警告: CRD 未 Established: ${crd}"
    fi
  done

  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo "错误: 仍没有 ServiceMonitor CRD，请检查 helm pull / 网络后重试"
    return 1
  fi
  log "Prometheus Operator CRD 已就绪"
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

storage = cfg.get("storage") or {}
storage_type = str(storage.get("type") or "nfs").strip().lower()
storage_class = str(storage.get("storageClass") or "ceph-rbd").strip()
storage_size = str(storage.get("size") or "").strip()
if storage_type not in ("nfs", "ceph-rbd"):
    raise SystemExit(f"storage.type 只支持 nfs | ceph-rbd，当前: {storage_type!r}")

nfs = cfg.get("nfs") or {}
server = str(nfs.get("server") or "").strip()
base_path = str(nfs.get("basePath") or "").rstrip("/")
if storage_type == "nfs" and (not server or not base_path):
    raise SystemExit("storage.type=nfs 需要 config.yaml 里的 nfs.server / nfs.basePath")

# 清掉上次生成的 PV/PVC 清单，避免切换存储后端/采集器后旧文件被误 apply
for stale in os.listdir(tmp):
    if (stale[:2].isdigit() and stale.endswith(".yaml")) or stale in ("loki-pvc.yaml", "tempo-pvc.yaml", "promtail.yaml"):
        os.remove(os.path.join(tmp, stale))

# 拆成多个小文件，串行 apply
parts = {
  "00-ns.yaml": """apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
""",
}

if storage_type == "nfs":
    # 静态 NFS PV（grafana 的 PV+PVC 同文件；loki/tempo 的 PVC 见下方单独文件）
    for i, (name, size) in enumerate(
        [("grafana", "10Gi"), ("prometheus", "50Gi"), ("alertmanager", "5Gi"),
         ("loki", "50Gi"), ("tempo", "20Gi")], start=1):
        if storage_size:
            size = storage_size
        body = f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mon-{name}
spec:
  capacity:
    storage: {size}
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["nfsvers=4.1", "hard", "timeo=600"]
  nfs:
    server: {server}
    path: {base_path}/{name}
"""
        if name == "grafana":
            body += f"""---
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
      storage: {size}
"""
        parts[f"{i:02d}-pv-{name}.yaml"] = body
else:
    # ceph-rbd：Grafana 用动态 PVC；Loki/Tempo/Prometheus/Alertmanager 由各自
    # volumeClaimTemplate 按 storageClassName 自动供给（见下方 values 改写）
    parts["01-pvc-grafana.yaml"] = f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-grafana
  namespace: monitoring
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {storage_class}
  resources:
    requests:
      storage: {storage_size or "10Gi"}
"""

for name, content in parts.items():
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        f.write(content)

if storage_type == "nfs":
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

    with open(os.path.join(tmp, "tempo-pvc.yaml"), "w", encoding="utf-8") as f:
        f.write(f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-tempo-0
  namespace: monitoring
  labels:
    app.kubernetes.io/name: tempo
    app.kubernetes.io/instance: tempo
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: pv-mon-tempo
  resources:
    requests:
      storage: 20Gi
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

tempo = cfg["tempo"]
tempo["replicas"] = 0

# 四个存储声明的引用（ceph 改写与统一容量都会用到）
am_vct = (((kp.get("alertmanager") or {}).get("alertmanagerSpec") or {})
          .get("storage") or {}).get("volumeClaimTemplate", {}).get("spec") or {}
pm_vct = (((kp.get("prometheus") or {}).get("prometheusSpec") or {})
          .get("storageSpec") or {}).get("volumeClaimTemplate", {}).get("spec") or {}
loki_p = (loki.get("singleBinary") or {}).setdefault("persistence", {})
tempo_p = tempo.setdefault("persistence", {})

if storage_type == "ceph-rbd":
    # 动态供给：去静态绑定（volumeName / 空 storageClassName），改 RWO + ceph-rbd
    # 注意字段名不同：loki chart 用 storageClass，tempo chart 用 storageClassName
    am_vct.pop("volumeName", None)
    am_vct["storageClassName"] = storage_class
    am_vct["accessModes"] = ["ReadWriteOnce"]
    pm_vct.pop("volumeName", None)
    pm_vct["storageClassName"] = storage_class
    pm_vct["accessModes"] = ["ReadWriteOnce"]
    loki_p["storageClass"] = storage_class
    loki_p["accessModes"] = ["ReadWriteOnce"]
    tempo_p["storageClassName"] = storage_class
    tempo_p["accessModes"] = ["ReadWriteOnce"]

if storage_size:
    # storage.size 统一覆盖 5 个组件的 PVC 容量
    for vct in (am_vct, pm_vct):
        vct.setdefault("resources", {}).setdefault("requests", {})["storage"] = storage_size
    loki_p["size"] = storage_size
    tempo_p["size"] = storage_size

for name, data in [
    ("kube-prometheus.yaml", kp),
    ("loki.yaml", loki),
    ("alloy.yaml", cfg["alloy"]),
    ("tempo.yaml", tempo),
]:
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)

print("generated:", tmp)
print(f"storage.type = {storage_type}")
if storage_size:
    print(f"storage.size = {storage_size}（统一覆盖 5 个组件 PVC 容量）")
if storage_type == "nfs":
    print("NFS 目录权限（在 {server} 执行）:".format(server=server))
    print(f"  mkdir -p {base_path}/{{prometheus,grafana,alertmanager,loki,tempo}}")
    print(f"  chown -R 472:472 {base_path}/grafana")
    print(f"  chown -R 1000:2000 {base_path}/prometheus")
    print(f"  chown -R 1000:2000 {base_path}/alertmanager")
    print(f"  chown -R 10001:10001 {base_path}/loki")
    print(f"  chown -R 10001:10001 {base_path}/tempo")
else:
    print(f"ceph-rbd 动态供给：StorageClass={storage_class}（先确认 kubectl get sc 有它）")
    print("RWO 卷属主由 fsGroup 自动处理，无需预建目录/chown")
PY
}

apply_storage_manifests() {
  log "串行应用存储清单（storage.type=${STORAGE_TYPE}）"
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
  if [ "$STORAGE_TYPE" = "ceph-rbd" ]; then
    echo "注意: ceph-rbd 动态卷 reclaimPolicy=Delete，PVC 删除后 RBD 数据不可恢复"
  fi
  wait_api

  log "缩容 Loki"
  kubectl -n "$NS" scale sts loki --replicas=0 2>/dev/null || true
  pause "$SLEEP_STEP"

  log "卸载 Helm（逐个）"
  wait_api
  helm -n "$NS" uninstall alloy promtail 2>/dev/null || true
  pause "$SLEEP_STEP"
  wait_api
  helm -n "$NS" uninstall tempo 2>/dev/null || true
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
  for pv in pv-mon-grafana pv-mon-prometheus pv-mon-alertmanager pv-mon-loki pv-mon-tempo; do
    kubectl patch pv "$pv" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    sleep 1
    kubectl delete pv "$pv" --ignore-not-found --wait=false 2>/dev/null || true
    sleep "$SLEEP_SHORT"
  done

  wait_ns_gone

  for pv in pv-mon-grafana pv-mon-prometheus pv-mon-alertmanager pv-mon-loki pv-mon-tempo; do
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

# ceph-rbd 模式：PVC 由 volumeClaimTemplate 动态供给，只需等 Bound
wait_pvc_bound() {
  local pvc="$1" phase i
  log "等待 PVC ${pvc} 动态供给 Bound"
  for i in $(seq 1 60); do
    phase=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Bound" ]; then
      kubectl -n "$NS" get pvc "$pvc"
      return 0
    fi
    sleep 2
  done
  if ! kubectl -n "$NS" get pvc "$pvc" >/dev/null 2>&1; then
    echo "错误: PVC ${pvc} 不存在（STS volumeClaimTemplate 未创建它；ceph-rbd 模式应直接 replicas=1 安装）"
  else
    echo "错误: PVC ${pvc} 未 Bound（检查 StorageClass ${STORAGE_CLASS} / ceph-csi 插件 / Ceph 连通性）"
    kubectl -n "$NS" describe pvc "$pvc" 2>/dev/null | tail -20 || true
  fi
  exit 1
}

ensure_tempo_pvc() {
  log "校正 Tempo PVC (${TEMPO_PVC})"
  kubectl -n "$NS" scale sts tempo --replicas=0 2>/dev/null || true
  pause "$SLEEP_STEP"

  kubectl -n "$NS" delete pvc "$TEMPO_PVC" --ignore-not-found --wait=false 2>/dev/null || true
  sleep "$SLEEP_SHORT"
  kubectl patch pv "$TEMPO_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true

  for i in $(seq 1 40); do
    kubectl -n "$NS" get pvc "$TEMPO_PVC" >/dev/null 2>&1 || break
    sleep 1
  done
  for i in $(seq 1 40); do
    st=$(kubectl get pv "$TEMPO_PV" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)
    [ "$st" = "Available" ] && break
    if [ "$st" = "Released" ] || [ "$st" = "Bound" ]; then
      kubectl patch pv "$TEMPO_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    fi
    sleep 1
  done

  wait_api
  kubectl create -f "$TMP/tempo-pvc.yaml"
  for i in $(seq 1 40); do
    phase=$(kubectl -n "$NS" get pvc "$TEMPO_PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Bound" ] && break
    sleep 1
  done

  kubectl -n "$NS" get pvc "$TEMPO_PVC"
  phase=$(kubectl -n "$NS" get pvc "$TEMPO_PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" != "Bound" ]; then
    echo "错误: ${TEMPO_PVC} 未 Bound"
    kubectl -n "$NS" describe pvc "$TEMPO_PVC" | tail -30 || true
    exit 1
  fi
  pause "$SLEEP_STEP"
}

# Envoy Gateway BackendRef 需要 gRPC；端口名已是 grpc-*，再显式打上 appProtocol
patch_tempo_otlp_grpc() {
  log "为 Tempo Service 4317 设置 appProtocol=grpc"
  if ! kubectl -n "$NS" get svc tempo >/dev/null 2>&1; then
    echo "警告: 未找到 Service tempo"
    return 0
  fi
  kubectl -n "$NS" get svc tempo -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d.get("spec", {}).get("ports", []):
    if p.get("port") == 4317 or str(p.get("name") or "").startswith("grpc-tempo-otlp"):
        p["appProtocol"] = "grpc"
print(json.dumps(d))
' | kubectl apply -f - >/dev/null
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

# Tempo 部署段（install_all 与单独安装共用）
deploy_tempo() {
  # 手工装过、没有 volumeClaimTemplates 的 Tempo 无法原地加持久卷，先删 STS
  if kubectl -n "$NS" get sts tempo >/dev/null 2>&1; then
    vct=$(kubectl -n "$NS" get sts tempo -o jsonpath='{.spec.volumeClaimTemplates}' 2>/dev/null || true)
    if [ -z "$vct" ] || [ "$vct" = "[]" ]; then
      log "已有 Tempo STS 未挂 PVC，删除以便改用持久卷（emptyDir 数据会丢失）"
      kubectl -n "$NS" delete sts tempo --wait=false --ignore-not-found 2>/dev/null || true
      pause "$SLEEP_STEP"
    fi
  fi

  if [ "$STORAGE_TYPE" = "ceph-rbd" ]; then
    # 动态供给：STS 在 replicas=0 时不会创建 PVC，直接 1 副本安装，
    # volumeClaimTemplate 会自动创建并供给（volumeBindingMode=Immediate）
    helm_retry "安装 Tempo" \
      helm upgrade --install tempo grafana/tempo \
        -n "$NS" \
        -f "$TMP/tempo.yaml" \
        --set replicas=1 \
        --timeout 30m \
        --wait=false
    wait_pvc_bound "$TEMPO_PVC"
    log "等待 Tempo STS 就绪"
    kubectl -n "$NS" rollout status sts/tempo --timeout=300s || true
  else
    helm_retry "安装 Tempo(replicas=0)" \
      helm upgrade --install tempo grafana/tempo \
        -n "$NS" \
        -f "$TMP/tempo.yaml" \
        --set replicas=0 \
        --timeout 30m \
        --wait=false

    for i in $(seq 1 40); do
      kubectl -n "$NS" get sts tempo >/dev/null 2>&1 && break
      sleep 3
    done

    ensure_tempo_pvc

    log "拉起 Tempo replicas=1"
    kubectl -n "$NS" scale sts tempo --replicas=1
    pause "$SLEEP_STEP"

    helm_retry "同步 Tempo(replicas=1)" \
      helm upgrade tempo grafana/tempo \
        -n "$NS" \
        -f "$TMP/tempo.yaml" \
        --set replicas=1 \
        --timeout 30m \
        --wait=false
  fi

  patch_tempo_otlp_grpc
}

# 只装 Tempo（不动 Prometheus/Loki/Alloy；用于先解决 x-trace-id 等链路追踪需求）
install_tempo() {
  export DIR
  echo "======== 单独安装 Tempo（storage.type=${STORAGE_TYPE}）========"
  need_py
  gen
  wait_api
  if [ "$STORAGE_TYPE" = "ceph-rbd" ]; then
    kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 \
      || { echo "错误: 未找到 StorageClass ${STORAGE_CLASS}（先装 install-ceph 的 CSI 并 apply csi/generated/）"; exit 1; }
    log "存储后端: ceph-rbd（StorageClass=${STORAGE_CLASS}，动态供给 RWO）"
  else
    log "存储后端: nfs（静态 PV）"
  fi
  kubectl apply -f "$TMP/00-ns.yaml"
  pause "$SLEEP_SHORT"
  if [ "$STORAGE_TYPE" = "nfs" ]; then
    kubectl apply -f "$TMP/05-pv-tempo.yaml"
    pause "$SLEEP_SHORT"
  fi
  log "更新 Grafana Helm 仓库"
  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  sleep 2
  helm repo update grafana 2>/dev/null || helm repo update
  prefetch_images tempo
  deploy_tempo

  echo "======== Tempo 状态 ========"
  kubectl -n "$NS" get pod,pvc,svc -l app.kubernetes.io/name=tempo
  echo ""
  echo "OTLP 接入地址（Envoy Gateway 的 eg-proxy.yaml 指向这里）:"
  echo "  gRPC: tempo.monitoring.svc.cluster.local:4317"
  echo "  HTTP: tempo.monitoring.svc.cluster.local:4318"
}

install_all() {
  export DIR
  echo "======== 安装监控（低并发串行）========"
  prefetch_images
  gen
  wait_api
  if [ "$STORAGE_TYPE" = "ceph-rbd" ]; then
    kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 \
      || { echo "错误: 未找到 StorageClass ${STORAGE_CLASS}"; \
           echo "先在 install-ceph 完成 bootstrap/add-hosts/osd/pool/export-rbd，并在本集群 apply csi/generated/"; exit 1; }
    log "存储后端: ceph-rbd（StorageClass=${STORAGE_CLASS}，动态供给 RWO）"
  else
    log "存储后端: nfs（静态 PV）"
  fi
  apply_storage_manifests

  log "更新 Helm 仓库"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  sleep 2
  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  sleep 2
  helm repo update
  pause "$SLEEP_STEP"

  install_prometheus_crds || exit 1

  # CRD 已就绪才 skip-crds；否则 helm 会报 ServiceMonitor mapping not found
  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo "错误: ServiceMonitor CRD 不存在，中止安装"
    exit 1
  fi

  # 优先 skip-crds（CRD 已串行预装）；失败再完整安装
  set +e
  helm_retry "安装 kube-prometheus-stack(skip-crds)" \
    helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
      -n "$NS" \
      --version "$KPS_CHART_VERSION" \
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
        --version "$KPS_CHART_VERSION" \
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

  if [ "$STORAGE_TYPE" = "ceph-rbd" ]; then
    # 动态供给：STS 在 replicas=0 时不会创建 PVC，直接 1 副本安装
    helm_retry "安装 Loki" \
      helm upgrade --install loki grafana/loki \
        -n "$NS" \
        -f "$TMP/loki.yaml" \
        --set singleBinary.replicas=1 \
        --timeout 30m \
        --wait=false
    wait_pvc_bound "$LOKI_PVC"
    log "等待 Loki STS 就绪"
    kubectl -n "$NS" rollout status sts/loki --timeout=300s || true
  else
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
  fi

  # 6. Alloy（日志采集，替代 Promtail；如有旧 Promtail 先卸载）
  log "安装 Alloy"
  if helm -n "$NS" status promtail >/dev/null 2>&1; then
    log "检测到旧 Promtail，卸载（日志采集由 Alloy 接管）"
    helm -n "$NS" uninstall promtail || true
    pause "$SLEEP_STEP"
  fi
  helm_retry "安装 Alloy" \
    helm upgrade --install alloy grafana/alloy \
      -n "$NS" \
      -f "$TMP/alloy.yaml" \
      --timeout 30m \
      --wait=false

  deploy_tempo

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
  echo "追踪: Grafana → Explore → Tempo"
  echo "OTLP: tempo.monitoring.svc.cluster.local:4317 (gRPC) / :4318 (HTTP)"
}

cmd="${1:-install}"
case "$cmd" in
  tempo)
    install_tempo
    ;;
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
    echo "用法: bash install.sh [install|tempo|images|reinstall|destroy]"
    exit 1
    ;;
esac
