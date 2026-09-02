#!/usr/bin/env bash
# 裸机安装 MetalLB（L2），给 Envoy Gateway LoadBalancer 分配局域网 IP
# 用法: bash install-metallb.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
GH_PROXY="${GH_PROXY:-https://ghfast.top/}"
NS="metallb-system"

echo "==> 安装 MetalLB ${METALLB_VERSION}"
MANIFEST_URL="${GH_PROXY}https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
curl -fL -o /tmp/metallb-native.yaml "${MANIFEST_URL}"
kubectl apply -f /tmp/metallb-native.yaml
kubectl -n "${NS}" wait --for=condition=Available deploy/controller --timeout=180s
kubectl -n "${NS}" wait --for=condition=ready pod -l app=speaker --timeout=180s || true

echo "==> 应用 IP 池（默认 172.16.10.250，勿与 API VIP .100 冲突）"
kubectl apply -f "${SCRIPT_DIR}/ipaddresspool.yaml"

echo
kubectl -n "${NS}" get pods
kubectl get ipaddresspool,l2advertisement -n "${NS}"
echo
echo "下一步: 在 gateway-api 目录把 NodePort 改成 LoadBalancer"
echo "  bash ensure-envoy-loadbalancer.sh"
echo "访问: http://172.16.10.250/"
