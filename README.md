# Janginmall - Infra

장인몰 프로젝트의 인프라 레포입니다.

## 팀 구성

통합 팀 내 Infra 팀원
- 클라우드 인프라: 강윤주(팀장), 신준한(부팀장), 박다정, 이창원
- 클라우드 네이티브: 박명수

## 사용 기술 및 도구

- 기술 스택
    - 코드형 인프라 (IaC): Terraform
    - 클라우드 플랫폼: AWS
        - EC2, EKS, ALB, VPC

- 사용 도구
    - CI/CD 배포 자동화: GitHub Actions, ArgoCD
    - 버전 관리: Git, GitHub
    - IDE & 터미널: VS Code
    - 아키텍처 디자인: Draw.io
    - 문서화 및 협업: Notion, Google Drive

## 컨벤션

커밋/PR 컨벤션은 [CONVENTION.md](./CONVENTION.md) 참고

## 구조

```

```

## Kubernetes 설정 검증

로컬과 GitHub Actions에서 같은 스크립트로 Kubernetes 설정을 검증한다.

```bash
bash scripts/validate-k8s.sh
```

- 필요 도구: Bash, kubectl, Helm. CI에서는 kubectl `v1.36.1`(Kustomize `v5.8.1`)과 Helm `v3.21.4`를 사용한다. 로컬도 같은 버전을 권장한다.
- 공개 Helm 저장소에 접근할 인터넷 연결이 필요하다. AWS 인증 정보와 kubeconfig는 필요하지 않다.
- 도구 사용법: `bash scripts/validate-k8s.sh --help`

| 검증 대상 | 수행 내용 | 고정 Chart 버전 |
| --- | --- | --- |
| `k8s/base` | `kubectl kustomize`로 리소스 참조와 렌더링 확인 | 해당 없음 |
| `k8s/overlays/stage` | Staging에서 사용할 공통 설정과 환경별 변경 사항의 렌더링 확인 | 해당 없음 |
| `k8s/overlays/prod` | Production에서 사용할 공통 설정과 환경별 변경 사항의 렌더링 확인 | 해당 없음 |
| `platform/cloudnative-pg` | `helm lint --strict` 및 `helm template --include-crds` | `0.29.0` |
| `platform/argo-rollouts` | `helm lint --strict` 및 `helm template --include-crds` | `2.43.1` |
| `platform/secrets-store-csi` | AWS Provider와 포함된 CSI Driver 차트 검증·렌더링 | `3.1.3` |
| `platform/aws-load-balancer-controller` | Stage·Prod 렌더링, TGB CRD·IRSA 연결 구조·웹훅 인증서 검증 | `1.14.0` |
| `platform/nvidia-device-plugin` | GPU DaemonSet·taint·장치 등록 설정 검증 | `0.20.0` |
| `platform/metrics-server` | Metrics API·자원·TLS·AppProject 권한 검증 | `3.14.0` |

차트는 고정 버전의 패키지를 임시 디렉터리에 받아 사용하며, 검증이 끝나면 다운로드·렌더링 결과를 삭제한다. Chart 버전을 변경할 때는 해당 플랫폼 문서·values의 버전 표기와 검증 스크립트를 함께 갱신한다.

### GitHub Actions 실행 조건

`Kubernetes validation` 워크플로는 `main` 대상 PR에서 `k8s/`, `platform/`, 검증 스크립트 또는 워크플로 파일이 변경되면 실행한다. 기본 브랜치에 반영된 뒤에는 Actions 화면에서 수동 실행도 가능하다.

- 표준 `ubuntu-24.04` runner의 단일 Job으로 실행한다.
- 같은 PR의 새 실행이 시작되면 이전 실행을 취소하며, 실행 제한 시간은 10분이다.
- GitHub 권한은 `contents: read`만 사용하고, 아티팩트 업로드와 Actions 캐시 저장은 구성하지 않는다.
- 실패하면 PR에 실패 상태가 표시된다. 현재처럼 경로 필터를 사용하는 워크플로를 모든 PR의 필수 검사로 지정하면, 관련 파일을 변경하지 않은 PR에서 검사가 대기 상태로 남을 수 있다. 필수 검사로 전환할 때는 실행 조건도 함께 조정한다.

### 검증 범위

이 검사는 YAML 생성·리소스 참조·Helm 차트 구조 및 차트가 제공하는 검증을 확인한다. Kubernetes API/CRD 스키마 전체 검증, 실제 EKS 버전 호환성, Pod 배치·통신·IRSA 인증·이미지 실행 검증은 별도로 수행한다. CI의 kubectl 버전은 검증 도구 버전이며 EKS 버전을 확정하는 값이 아니다.

검증 대상에는 공통 base, Stage/Prod overlay, 위 플랫폼과 관측성·백업 구성이 포함된다. 새 환경이나 플랫폼을 추가할 때 검증 스크립트에도 대상을 추가한다. 환경별 설정 구조와 개별 렌더링 방법은 [Kubernetes 안내](k8s/README.md)를 참고한다.

ALB Controller·Metrics Server의 실제 설치 순서, 인프라 인계값과 수용 시험은 [클러스터 애드온 운영 문서](platform/cluster-addons.md)를 따른다. 설치 코드는 준비되어 있으나 실제 EKS 설치 완료를 뜻하지 않는다.
