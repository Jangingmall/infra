# [K8s] 클러스터 안 배포 - 순수 애플리케이션 매니페스트

## 공통 설정과 환경별 설정

`base`는 Namespace, StorageClass, Backend, DB, AI의 공통 설정을 관리한다. `overlays/stage`와 `overlays/prod`는 이 공통 설정을 참조하는 환경별 진입점이다.

| 경로 | 용도 |
| --- | --- |
| `base` | 모든 환경이 공유하는 Kubernetes 리소스 |
| `overlays/stage` | Staging 클러스터의 배포 설정 |
| `overlays/prod` | Production 클러스터의 배포 설정 |

폴더 이름 `stage`는 [GitOps 설계](https://app.notion.com/p/bd40842d874f8338b21d01984da9bcf4)의 표기를 따른다. AWS 환경 이름 `staging`을 변경하는 설정이 아니다.

Stage와 Prod는 별도 EKS 클러스터를 사용하는 설계다. 따라서 Namespace, Service, ServiceAccount 등 리소스 이름은 공통 base의 이름을 유지한다. 두 overlay를 같은 클러스터에 적용하면 같은 리소스를 갱신하므로 환경이 분리되지 않는다. 실제 배포 연결 시 각 환경의 Argo CD Application이 올바른 클러스터를 가리키도록 구성해야 한다.

## 현재 구현 범위

현재 두 overlay에는 `resources: ../../base` 참조만 있으며, 렌더링 결과는 base와 같다. 환경별 차이가 확정되면 해당 overlay에 `patches` 또는 `images` 설정을 추가한다.

- 이미지: Backend·AI의 실제 ECR 이미지가 전달되면 환경별 `images`로 지정한다. Production은 Staging에서 검증한 동일 이미지 SHA/Digest를 사용한다.
- Replica·CPU·메모리: 현재 base 값을 상속한다. 환경별 운영 수치가 확정되면 patch로 관리한다.
- 도메인·IRSA·시크릿: 실제 연결 값과 사용 방식이 확정된 뒤 환경별 설정을 추가한다.

Backend·AI 이미지에는 아직 base의 자리표시자(`jangin-app`, `jangin-ai`)가 사용된다. 이번 구조 추가는 배포 준비 단계이며, 실제 이미지·인증·설정 연결 및 EKS 실행 검증까지 완료된 상태는 아니다.

## 로컬 렌더링과 검증

저장소 루트에서 실행한다. 아래 명령은 최종 YAML을 출력하며 클러스터에 적용하지 않는다.

```bash
kubectl kustomize k8s/overlays/stage
kubectl kustomize k8s/overlays/prod
```

공통 base, 두 overlay와 기존 세 플랫폼 Helm 차트를 함께 검증하려면 다음을 실행한다.

```bash
bash scripts/validate-k8s.sh
```

GitHub Actions도 같은 스크립트를 실행한다. 도구 버전, 실행 조건과 검증의 한계는 [저장소 검증 안내](../README.md#kubernetes-설정-검증)를 참고한다.
