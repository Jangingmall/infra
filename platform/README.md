# Platform

장인몰 EKS 클러스터에서 공용으로 사용하는 Kubernetes Platform 및 Operator 설정을 관리한다.

애플리케이션 자체의 Kubernetes 리소스와 외부 Platform/Operator의 설치 설정을 분리하여 관리한다.

---

## 디렉터리 관리 원칙

| 디렉터리     | 관리 대상                      | 주요 도구 |
| ------------ | ------------------------------ | --------- |
| `terraform/` | AWS 인프라 및 EKS 기반 리소스  | Terraform |
| `k8s/`       | 장인몰 Application Workload    | Kustomize |
| `platform/`  | Kubernetes Platform / Operator | Helm      |
| `argocd/`    | Argo CD Application / Project  | Argo CD   |

## Argo CD

[Argo CD 설치 설정](argocd/README.md)은 chart 10.9.1을 고정하고 환경별 System 노드에 설치한다.
Application·AppProject 및 GitOps 운영 절차는 [argocd](../argocd/README.md)에서 관리한다.
