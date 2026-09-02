#!/usr/bin/env bash
# 数据面 Service → LoadBalancer（MetalLB）+ 80/443
# 默认安装是 NodePort；本脚本为可选步骤，会 apply eg-proxy-loadbalancer.yaml
# MetalLB v0.14 原生 manifest 不含 LoadBalancerClass；不要同时写 spec.loadBalancerIP 与 annotation
# 用法（Gateway 已创建、MetalLB 已装）:
#   bash ../metallb/install-metallb.sh
#   bash ensure-envoy-loadbalancer.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GW_NAME="${1:-eg}"
GW_NS="${2:-default}"
SYS_NS="envoy-gateway-system"
LB_IP="${LB_IP:-172.16.10.250}"

preflight_metallb() {
  if ! kubectl get ns metallb-system >/dev/null 2>&1; then
    echo "❌ 未找到命名空间 metallb-system，请先执行:"
    echo "   bash ${SCRIPT_DIR}/../metallb/install-metallb.sh"
    exit 1
  fi
  if ! kubectl -n metallb-system get deploy controller >/dev/null 2>&1; then
    echo "❌ MetalLB controller 未安装，请先 bash ../metallb/install-metallb.sh"
    exit 1
  fi
  if ! kubectl get ipaddresspool -n metallb-system lan-pool >/dev/null 2>&1; then
    echo "❌ 未找到 IPAddressPool lan-pool，请先:"
    echo "   kubectl apply -f ${SCRIPT_DIR}/../metallb/ipaddresspool.yaml"
    exit 1
  fi
  echo "✅ MetalLB 已就绪"
  kubectl apply -f "${SCRIPT_DIR}/../metallb/ipaddresspool.yaml"
  echo "  已同步 IPAddressPool → ${LB_IP}"
  kubectl -n metallb-system get pods --no-headers 2>/dev/null | awk '{print "   "$1" "$3}' || true
}

find_data_plane_svc() {
  kubectl -n "${SYS_NS}" get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_for_data_plane_svc() {
  local name=""
  for i in $(seq 1 30); do
    name="$(find_data_plane_svc)"
    [[ -n "${name}" ]] && { echo "${name}"; return 0; }
    echo "  等待 Service… (${i}/30)"
    sleep 2
  done
  return 1
}

patch_svc_lb() {
  local name="$1"
  # MetalLB: 只能二选一。用 annotation 指定 VIP，不要再写 spec.loadBalancerIP
  kubectl -n "${SYS_NS}" patch svc "${name}" --type merge -p "{
    \"metadata\": {
      \"annotations\": {
        \"metallb.universe.tf/loadBalancerIPs\": \"${LB_IP}\"
      }
    },
    \"spec\": {
      \"type\": \"LoadBalancer\",
      \"externalTrafficPolicy\": \"Cluster\"
    }
  }"
  local lbip
  lbip="$(kubectl -n "${SYS_NS}" get svc "${name}" -o jsonpath='{.spec.loadBalancerIP}' 2>/dev/null || true)"
  if [[ -n "${lbip}" ]]; then
    echo "  去掉 spec.loadBalancerIP=${lbip}（与 annotation 冲突会导致分配失败）"
    kubectl -n "${SYS_NS}" patch svc "${name}" --type json -p '[{"op":"remove","path":"/spec/loadBalancerIP"}]'
  fi
}

# loadBalancerClass 一旦设置且集群无对应 controller，会永远 pending；K8s 也不允许事后删除
ensure_no_load_balancer_class() {
  local name="$1"
  local current
  current="$(kubectl -n "${SYS_NS}" get svc "${name}" -o jsonpath='{.spec.loadBalancerClass}' 2>/dev/null || true)"

  if [[ -z "${current}" ]]; then
    echo "  loadBalancerClass 未设置（MetalLB v0.14 正确状态）"
    return 0
  fi

  echo "  ⚠ Service 带有 loadBalancerClass=${current}，但 MetalLB v0.14 无此 CR，会导致永远 pending"
  echo "  删除 Service 由 Envoy Gateway 重建（不带 loadBalancerClass）…"
  kubectl -n "${SYS_NS}" delete svc "${name}" --wait=true

  echo "  等待 Envoy Gateway 重建 Service…"
  if ! name="$(wait_for_data_plane_svc)"; then
    echo "❌ 重建超时，请确认 Gateway ${GW_NS}/${GW_NAME} 存在且 EG controller 正常"
    exit 1
  fi
  echo "  新 Service: ${SYS_NS}/${name}"
  svc="${name}"
}

echo "==> 预检 MetalLB"
preflight_metallb

echo "==> 应用 EnvoyProxy（LoadBalancer ${LB_IP}）"
kubectl apply --server-side --force-conflicts -f "${SCRIPT_DIR}/eg-proxy-loadbalancer.yaml"

echo "==> 查找数据面 Service"
svc=""
if ! svc="$(wait_for_data_plane_svc)"; then
  echo "未找到数据面 Service，请先 kubectl apply -f examples/gateway-http.yaml"
  exit 1
fi
echo "  Service: ${SYS_NS}/${svc}"

ensure_no_load_balancer_class "${svc}"
patch_svc_lb "${svc}"

# 改 VIP 后旧 EXTERNAL-IP 不在新池内，speaker 会拒配置；删掉让 EG 按新 annotation 重建
cur_ext="$(kubectl -n "${SYS_NS}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -n "${cur_ext}" && "${cur_ext}" != "${LB_IP}" ]]; then
  echo "  当前 EXTERNAL-IP=${cur_ext} ≠ ${LB_IP}，删除 Service 以便按新 VIP 重建…"
  kubectl -n "${SYS_NS}" delete svc "${svc}" --wait=true
  if ! svc="$(wait_for_data_plane_svc)"; then
    echo "❌ 重建超时"
    exit 1
  fi
  echo "  新 Service: ${SYS_NS}/${svc}"
  patch_svc_lb "${svc}"
fi

echo "==> 等待 EXTERNAL-IP（MetalLB controller 分配）"
ext=""
for i in $(seq 1 40); do
  ext="$(kubectl -n "${SYS_NS}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${ext}" ]]; then
    echo "  EXTERNAL-IP=${ext}"
    break
  fi
  echo "  pending… (${i}/40)"
  sleep 3
done

kubectl -n "${SYS_NS}" get svc "${svc}" -o wide
echo

if [[ -z "${ext}" ]]; then
  echo "❌ 仍为 pending，请在本机执行排查:"
  echo "   kubectl -n metallb-system logs deploy/controller --tail=40"
  echo "   kubectl -n metallb-system logs ds/speaker --tail=20"
  echo "   kubectl -n ${SYS_NS} get svc ${svc} -o yaml | grep -E 'loadBalancerClass|loadBalancerIP|metallb'"
  echo "   kubectl -n ${SYS_NS} describe svc ${svc} | tail -20"
  echo "   ping -c1 ${LB_IP}   # 若已 ping 通说明 IP 被别的主机占用，需换池内地址"
  exit 1
fi

echo "HTTP:  http://${LB_IP}/"
echo "HTTPS: https://${LB_IP}/   # 需 Gateway 已加 443 listener + TLS Secret"
echo "域名把 A 记录指到 ${LB_IP} 即可用 80/443"
