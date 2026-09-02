#!/usr/bin/env bash
# MetalLB + Envoy 数据面 LoadBalancer 排查
# 用法: bash diagnose-metallb-lb.sh [svc-name]
set -euo pipefail

SYS_NS="envoy-gateway-system"
SVC="${1:-envoy-default-eg-e41e7b31}"
LB_IP="${LB_IP:-172.16.10.250}"

section() { echo; echo "======== $* ========"; }

section "MetalLB"
kubectl get ns metallb-system >/dev/null 2>&1 && kubectl -n metallb-system get pods || echo "metallb-system 不存在"
kubectl get ipaddresspool,l2advertisement -n metallb-system 2>/dev/null || true
kubectl get loadbalancerclass 2>/dev/null || echo "（集群无 LoadBalancerClass CR，Service 上不应写 loadBalancerClass）"

section "EnvoyProxy CR"
kubectl -n "${SYS_NS}" get envoyproxy eg-proxy -o yaml 2>/dev/null | grep -A25 'envoyService:' || echo "eg-proxy 不存在"

section "数据面 Service: ${SYS_NS}/${SVC}"
if kubectl -n "${SYS_NS}" get svc "${SVC}" >/dev/null 2>&1; then
  kubectl -n "${SYS_NS}" get svc "${SVC}" -o wide
  echo
  kubectl -n "${SYS_NS}" get svc "${SVC}" -o jsonpath='  type={.spec.type} loadBalancerClass={.spec.loadBalancerClass} loadBalancerIP={.spec.loadBalancerIP}{"\n"}'
  kubectl -n "${SYS_NS}" get svc "${SVC}" -o jsonpath='  annotation={.metadata.annotations.metallb\.universe\.tf/loadBalancerIPs}{"\n"}'
  kubectl -n "${SYS_NS}" get svc "${SVC}" -o jsonpath='  EXTERNAL-IP={.status.loadBalancer.ingress[0].ip}{"\n"}'
  lbclass="$(kubectl -n "${SYS_NS}" get svc "${SVC}" -o jsonpath='{.spec.loadBalancerClass}' 2>/dev/null || true)"
  if [[ -n "${lbclass}" ]]; then
    echo "  ⚠ loadBalancerClass=${lbclass} — MetalLB v0.14 无对应 CR 时会永远 pending"
    echo "    修复: 应用无 loadBalancerClass 的 eg-proxy.yaml 后 delete svc 重建"
  fi
else
  echo "Service 不存在"
fi

section "MetalLB controller 最近日志"
kubectl -n metallb-system logs deploy/controller --tail=30 2>/dev/null || echo "controller 不存在"

section "独立测试 Service（验证 MetalLB 能否分配 ${LB_IP}）"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: metallb-lb-test
  namespace: default
  annotations:
    metallb.universe.tf/loadBalancerIPs: "${LB_IP}"
spec:
  type: LoadBalancer
  ports:
    - port: 18080
      targetPort: 18080
  selector:
    app: metallb-lb-test-nonexistent
EOF
echo "等待 15s…"
sleep 15
kubectl get svc metallb-lb-test -n default -o wide || true
test_ip="$(kubectl get svc metallb-lb-test -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -n "${test_ip}" ]]; then
  echo "✅ MetalLB 可分配 IP → 问题在 Envoy Service 配置（常见: loadBalancerClass）"
else
  echo "❌ 测试 Service 也 pending → MetalLB 本身有问题，看 controller 日志"
fi
kubectl delete svc metallb-lb-test -n default --ignore-not-found

section "网络"
ping -c1 -W2 "${LB_IP}" 2>/dev/null && echo "${LB_IP} 已有主机响应（可能 IP 冲突）" || echo "${LB_IP} 当前 ping 不通（正常，MetalLB 未宣告前）"
