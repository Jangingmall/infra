# Platform

EKS 클러스터에서 공용으로 사용하는 Kubernetes 플랫폼 및 Operator 설정을 관리한다.

## 관리 원칙

- AWS 인프라 및 EKS 관리형 Add-on: `terraform/`
- 장인몰 Application Workload: `k8s/`
- Kubernetes Platform / Operator: `platform/`
- Argo CD Application / Project: `argocd/`

## 예정 Platform

- CloudNativePG Operator
- Metrics Server
- AWS Load Balancer Controller
- Secrets Store CSI Driver
- Argo CD
- kube-prometheus-stack
