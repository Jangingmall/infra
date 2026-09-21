# ALB Controller · Metrics Server 설치 및 인계

## 역할과 배포 범위

| 구성 | Chart / 앱 버전 | 역할 | 배포 위치 |
| --- | --- | --- | --- |
| AWS Load Balancer Controller | 1.14.0 / v2.14.0 | 기존 ALB Target Group에 Backend Pod IP 등록 | kube-system, System 노드, 2 replicas |
| Metrics Server | 3.14.0 / v0.9.0 | HPA·kubectl top용 metrics.k8s.io API | kube-system, System 노드, 1 replica |

각 환경의 `argocd/applications/{stage,prod}/cluster-addons.yaml`이 설치를 관리한다.
두 환경은 별도 EKS다. 한 클러스터에 Stage와 Prod Application을 함께 적용하지 않는다.
자동 Sync·selfHeal·prune은 꺼져 있다. merge 또는 Application 등록만으로 설치되지 않으며 운영자가 수동 Sync한다.
Argo CD가 관리하기 시작하면 같은 release를 수동 Helm으로 동시에 관리하지 않는다.

### 기존 CSI와의 관계

- EBS CSI Driver: Terraform `eks_addons`가 설치한다. 이 작업에서 중복 설치하지 않는다.
- Secrets Store CSI Driver + AWS Provider: 기존 `*-secrets-store-csi` Application이 설치한다.
- 두 새 구성은 CSI를 대체하지 않는다. HPA 2~4, Backend 메모리 상한, 업무 NetworkPolicy도 변경하지 않는다.

## 자원과 인증서

| 구성 | Pod당 requests | Pod 수 | 합계 requests | Pod당 메모리 limit |
| --- | --- | --- | --- | --- |
| ALB Controller | 100m / 128Mi | 2 | 200m / 256Mi | 256Mi |
| Metrics Server | 100m / 200Mi | 1 | 100m / 200Mi | 400Mi |
| 추가 합계 | — | 3 | **300m / 456Mi** | — |

실측 전 초기값이다. 기존 System 워크로드·DaemonSet·rolling update 여유까지 합쳐 노드 allocatable 안에 들어가는지 배포 전에 확인한다.
ALB chart의 기본 preferred anti-affinity로 두 Controller를 가능한 다른 노드에 둔다.
Metrics Server는 1개이므로 재시작 중에는 지표 조회/HPA 계산이 잠시 중단될 수 있다. 노드 자동 확장은 제공하지 않는다.

두 chart 모두 **기존 cert-manager**를 먼저 요구한다. ALB webhook과 Metrics API의 serving 인증서를 발급·갱신한다.
Helm에서 매 렌더링마다 임의 인증서를 만들지 않아 GitOps diff가 반복되지 않는다.
cert-manager가 주입하는 webhook/APIService `caBundle`만 ignoreDifferences로 제외하고, 나머지 설정은 계속 비교한다.
Metrics API의 TLS 검증과 Metrics Server→kubelet TLS 검증을 유지한다. `--kubelet-insecure-tls`로 인증서 문제를 우회하지 않는다.

## 인프라에서 받을 값

환경별 `platform/aws-load-balancer-controller/runtime/{stage,prod}.yaml`에 입력한다.

| Helm 값 | 인계값 / 조건 |
| --- | --- |
| clusterName | 실제 EKS 이름. 현재 값은 Terraform 예시와 동일하며 output과 대조 |
| region | 실제 리전. 현재 ap-northeast-2 |
| vpcId | 실제 Terraform vpc_id. 현재 빈 값 |
| serviceAccount.annotations.eks.amazonaws.com/role-arn | irsa_role_arns의 alb-controller ARN. 현재 미입력 |

IRSA trust subject는 `system:serviceaccount:kube-system:aws-load-balancer-controller`, audience는 `sts.amazonaws.com`이어야 한다.
Chart 1.14.0의 Controller v2.14.0에 필요한 IAM 정책과 기존 Terraform 정책을 인프라 담당자가 대조한다.
AWS 장기 키를 Pod에 넣지 않으며, IMDS fallback을 끈다. VPC ID와 IRSA가 없으면 Controller를 Sync하지 않는다.

ALB·Target Group·WAF·SG는 Terraform 소유다. Controller는 현재 TGB의 Pod 등록을 수행한다.
IngressClass 생성, Service의 자동 LoadBalancer class 주입, WAF/Shield·공유 backend SG 기능은 껐다.
이 설정 자체가 IAM 권한을 축소하는 것은 아니다. 새로운 Ingress/LoadBalancer Service 도입은 별도 검토한다.

### 필요한 통신

| 출발지 | 목적지 | 포트 / 용도 |
| --- | --- | --- |
| EKS control plane | ALB Controller Pod | TCP 9443, admission webhook |
| EKS control plane | Metrics Server Pod | TCP 10250, 집계 API (Service 443→Pod 10250) |
| Metrics Server | 각 노드 kubelet InternalIP | TCP 10250, 자원 지표 |
| ALB Controller | EKS API·STS·EC2·ELB API | TCP 443, 조회·인증·타깃 등록 |
| 두 Pod | 클러스터 DNS | TCP/UDP 53 |

인프라 SG/라우팅과 Kubernetes 정책을 함께 확인한다. Backend용 ALB 8080 통신 허용만으로 위 경로가 보장되지는 않는다.

## 최초 설치 순서

아래는 EKS 준비 후 실행할 운영 절차다. 로컬 검증이나 이번 코드 작성에서는 실행하지 않는다.
Git main merge·Argo CD Git 읽기 권한·올바른 클러스터 접속을 먼저 확인한다.
이미 metrics-server EKS 애드온 또는 수동 Helm 설치가 있으면 먼저 소유권을 인계한다. 두 설치 방식으로 중복 관리하지 않는다.

1. 실제 ALB runtime 값을 입력하고 변경을 main에 반영한다.
2. `ruby scripts/validate-cluster-addons.rb --ready stage`로 값 존재·형식을 확인한다. 이 검사는 실제 AWS 존재·IAM trust를 조회하지 않는다.
3. 선택한 환경의 AppProject를 등록한다.
4. 기존 cert-manager Application을 등록·Sync하고 Controller/webhook/cainjector가 준비됐는지 확인한다.
5. 새 두 Application을 등록한다. Metrics Server, ALB Controller를 수동 Sync한다.
6. 인증서 Ready, CRD Established, Deployment Available, Metrics API Available을 확인한다.
7. Backend 이미지·Secret·DB 등 별도 선행 조건을 만족한 후 업무 앱을 배포한다.
8. 실제 TG/VPC/ALB CIDR을 `platform/networking/{stage,prod}.yaml`에 반영하고 `*-backend-networking`을 Sync한다.
9. ALB target healthy·Backend 응답·HPA 지표를 검증한다. HPA 증감은 별도 부하 테스트로 확인한다.

Stage 예시. `KUBE_CONTEXT`에는 실제 Stage context를 넣고 Argo CD CLI도 같은 Stage 서버에 로그인한다.

```bash
KUBE_CONTEXT='<실제 Stage context>'
ruby scripts/validate-cluster-addons.rb --ready stage
kubectl --context "$KUBE_CONTEXT" apply -f argocd/applications/stage/projects.yaml
kubectl --context "$KUBE_CONTEXT" apply -f argocd/applications/stage/backup.yaml
argocd app sync stage-cert-manager
argocd app wait stage-cert-manager --sync --health --timeout 600
kubectl --context "$KUBE_CONTEXT" -n cert-manager rollout status deployment/cert-manager --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
kubectl --context "$KUBE_CONTEXT" apply -f argocd/applications/stage/cluster-addons.yaml
argocd app sync stage-metrics-server
argocd app wait stage-metrics-server --sync --health --timeout 600
argocd app sync stage-aws-load-balancer-controller
argocd app wait stage-aws-load-balancer-controller --sync --health --timeout 600
```

`backup.yaml`은 cert-manager와 함께 다른 백업 Application도 등록하지만 자동 Sync가 꺼져 있으므로 백업을 활성화하지 않는다.
별도 Application 사이의 설치 순서는 sync-wave만으로 보장되지 않는다. 위 준비 확인을 생략하지 않는다.
Prod는 Prod context·Argo CD 서버와 `prod` 파일/Application을 사용한다.

## 실제 EKS 확인

```bash
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established crd/targetgroupbindings.elbv2.k8s.aws --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n kube-system wait --for=condition=Ready certificate/aws-load-balancer-serving-cert certificate/metrics-server --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
kubectl --context "$KUBE_CONTEXT" top nodes
kubectl --context "$KUBE_CONTEXT" -n app top pods
kubectl --context "$KUBE_CONTEXT" -n app get hpa backend
kubectl --context "$KUBE_CONTEXT" -n app get targetgroupbinding backend
```

- ALB Controller 로그에 STS/EC2/ELB `AccessDenied` 또는 VPC discovery 실패가 없어야 한다.
- AWS target health와 실제 API 응답을 확인한다. TGB CRD가 있다는 사실만으로 ALB 연결 성공을 판정하지 않는다.
- HPA CPU가 `<unknown>`이면 Metrics API, Backend CPU requests, 실제 지표 수집 상태를 확인한다.
- Metrics API 인증서 오류는 cert-manager 발급·CA 주입·통신을 확인한다. kubelet 인증서 오류는 노드의 serving 인증서·주소를 확인한다.
- 기존 HPA min 2 / max 4를 유지한다. Node 수와 Pod 수를 같게 맞추지 않는다. Blue/Green 전환 여유를 별도 확보한다.

## 로컬 검증

```bash
bash scripts/validate-k8s.sh
ruby scripts/validate-cluster-addons.rb --help
ruby scripts/validate-cluster-addons.rb --ready stage
ruby scripts/validate-cluster-addons.rb --ready prod
```

전체 검증은 Helm lint·EKS 1.35 대상 렌더링, Stage/Prod Argo Application 권한, TGB CRD·Metrics API, System 배치·자원·TLS/CA 소유권을 확인한다.
실제 값이 비어 있어도 코드 렌더링 검증은 통과하며 경고한다. `--ready`는 현재 미입력 상태에서 의도적으로 실패한다.
실제 클러스터 인증·스케줄링·AWS API·HPA 증감은 EKS에서 별도로 검증한다.

## 근거

- [AWS Load Balancer Controller Helm chart](https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller)
- [Controller v2.14.0 IAM 정책](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.0/docs/install/iam_policy.json)
- [Metrics Server 설치·요구사항](https://github.com/kubernetes-sigs/metrics-server)
- [Metrics Server Helm chart](https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server)

## NVIDIA Device Plugin

- Chart / image: `0.20.0` / `nvcr.io/nvidia/k8s-device-plugin:v0.20.0`.
- Stage·Prod `*-nvidia-device-plugin` Application, `kube-system` namespace, 수동 Sync.
- `workload-type=gpu` Linux 노드마다 DaemonSet Pod 1개. GPU taint `nvidia.com/gpu=true:NoSchedule` 허용.
- Pod당 requests 50m/64Mi, memory limit 256Mi. L40S/T4 두 노드에 총 100m/128Mi 추가. System 노드 예산에는 포함하지 않는다.
- 드라이버·Container Toolkit은 `AL2023_x86_64_NVIDIA` AMI가 제공한다. 기본 NVIDIA runtime을 사용하며 별도 RuntimeClass/GPU Operator를 설치하지 않는다.
- 공식 차트는 MPS DaemonSet 정의도 생성하지만 `nvidia.com/mps.capable=true` 노드에서만 실행된다. 현재 Terraform은 이 라벨을 부여하지 않으므로 MPS Pod는 0개다. 이 라벨을 임의로 추가하지 않는다. GFD/NFD·MIG·time-slicing·MPS 공유를 활성화하지 않는다. Plugin Pod 자체는 GPU를 예약하지 않는다.
- 차트의 ServiceAccount·ClusterRole은 Kubernetes Node 조회(get/list/watch)에 사용한다. Pod→Kubernetes API TCP443·DNS 통신을 허용해야 하며 AWS IRSA는 필요하지 않다.
- 초기 GPU 탐지 실패를 오류로 표시한다. GPU 노드 0대에서는 DaemonSet Pod 0개이며, 이 상태는 GPU 검증 성공이 아니다.
- NVIDIA 이미지는 노드가 `nvcr.io`에서 pull한다. 인프라가 해당 레지스트리·이미지 레이어 다운로드 통신을 허용해야 한다. ECR 전용 사설 경로만으로는 충분하지 않다. 차트 저장소 접근은 Argo CD repo-server가 필요하다.

### 배포 순서와 실제 수용 시험

1. main에 설정 반영 후 GPU 노드 기동, NVIDIA AMI·드라이버·기본 container runtime 준비를 확인한다.
2. 선택 환경 projects.yaml과 cluster-addons.yaml을 등록하고 아래 NVIDIA Application만 수동 Sync한다. ALB/metrics와 달리 cert-manager·IRSA가 필요하지 않다.
3. Plugin 준비와 각 노드의 `nvidia.com/gpu=1` 등록을 확인한 뒤 AI를 배포한다. 기존 수동 Plugin이나 GPU Operator가 있다면 중복 설치하지 않는다.

```bash
# KUBE_CONTEXT 및 Argo CD 로그인 대상을 Stage로 맞춘 뒤 실행한다.
kubectl --context "$KUBE_CONTEXT" apply -f argocd/applications/stage/projects.yaml
kubectl --context "$KUBE_CONTEXT" apply -f argocd/applications/stage/cluster-addons.yaml
argocd app sync stage-nvidia-device-plugin
argocd app wait stage-nvidia-device-plugin --sync --health --timeout 600
kubectl --context "$KUBE_CONTEXT" -n kube-system rollout status daemonset/nvidia-device-plugin --timeout=180s
kubectl --context "$KUBE_CONTEXT" get nodes -l workload-type=gpu -o 'custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
kubectl --context "$KUBE_CONTEXT" -n kube-system logs daemonset/nvidia-device-plugin --all-pods=true --tail=100
```

노드별 allocatable 값 1은 등록된 GPU 총량이며 현재 미할당 수량이 아니다. 두 GPU 노드를 기동했다면 출력 행도 2개여야 한다.
AI 배포 후 실제 GPU 할당 컨테이너에서 `nvidia-smi`와 추론 요청을 실행한다. 모델 초기화·CUDA 호환성과 결과까지 확인한다.
Plugin만 정상이어도 미구현 챗봇 LLM 연결·모델·Secret 문제까지 해결되는 것은 아니다.
Prod도 해당 환경 context·Application으로 같은 순서를 수행한다. 드라이버 버전과 실제 추론은 EKS에서 별도 검증한다.

근거: [NVIDIA chart 0.20.0](https://github.com/NVIDIA/k8s-device-plugin/tree/v0.20.0/deployments/helm/nvidia-device-plugin), [EKS NVIDIA AMI 구성](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html).
