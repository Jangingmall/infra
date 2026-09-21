# Argo CD · Stage/Prod GitOps

## 범위와 결정

[GitOps 설계](https://app.notion.com/p/bd40842d874f8338b21d01984da9bcf4)와
[최신 협업 흐름](https://app.notion.com/p/3dd0842d874f8125ac29fe52292d7504)을 기준으로 작성한다.

- Stage·Prod는 별도 EKS이며 각 환경에 Argo CD를 설치한다. 각 Application의 local API 주소는 **그 Argo CD가 설치된 클러스터**다.
- `applications/stage`는 Stage에서만, `applications/prod`는 Prod에서만 등록한다. 한 클러스터에 둘 다 적용하지 않는다.
- `infra/main`을 추적한다. 이 작업 브랜치가 main에 merge되기 전에는 Application을 등록하지 않는다.
- 현재 overlay는 Backend·DB·AI·Namespace·스토리지를 함께 포함한다. 중복 소유를 피하려고 환경당 `*-workloads` Application 하나가 소유한다.
- 설계의 기능별 Application 분리는 독립 Kustomize 진입점이 준비될 때 진행한다. 같은 overlay를 Backend/AI Application에 중복 등록하지 않는다.
- 기존 workloads/platform은 Stage·Prod 모두 PR merge 후 auto-sync/selfHeal을 사용한다. 새 관측성 Application은 선행조건 확인을 위해 최초 수동 sync로 시작한다. Prod 자동 동기화는 Prod 승격 PR 승인 이후에만 변경을 전달한다.
- ALB Controller·Metrics Server는 `cluster-addons.yaml`에서 별도 수동 Sync로 시작한다. cert-manager 및 실제 AWS 값 준비가 선행한다.
- Backend Blue/Green 트래픽 승격은 auto-sync와 별개로 운영자가 수행한다.

## 파일과 소유권

환경별 `projects.yaml`에는 workload와 platform AppProject를 나눈다. `observability-project.yaml`은 관측성 chart·수집 namespace·리소스 종류를 별도로 허용한다.
workload는 지정 Git 저장소, local cluster, 지정 Namespace와 현재 필요한 리소스 종류만 허용한다.
platform은 고정된 chart 저장소와 설치 Namespace, CRD·RBAC·webhook·CSI 리소스를 허용한다.
Platform project는 operator 설치를 위해 강한 권한을 사용하므로 운영자만 Application을 수정한다.
AppProject는 Argo CD 내부 제한이며 Kubernetes 사용자 RBAC 또는 GitHub branch protection을 대체하지 않는다.

환경별 Application:

| Application 접미사 | 소스 | 역할 |
| --- | --- | --- |
| cloudnative-pg | chart 0.29.0 + infra/main values | CNPG Operator |
| argo-rollouts | chart 2.43.1 + infra/main values | Rollouts Controller/CRD |
| secrets-store-csi | chart 3.1.3 + infra/main values | CSI Driver + AWS Provider |
| aws-load-balancer-controller | chart 1.14.0 + 공통/환경 runtime values | 기존 ALB TG에 Pod 등록, 최초 수동 Sync |
| nvidia-device-plugin | chart 0.20.0 + 공통 values | GPU 노드별 장치 등록, 최초 수동 Sync |
| metrics-server | chart 3.14.0 + 공통 values | HPA·kubectl top용 Metrics API, 최초 수동 Sync |
| backend-networking | platform/networking + 환경별 values | 기존 ALB TargetGroupBinding·수신 정책, 값 준비 후 수동 Sync |
| workloads | k8s/overlays/stage 또는 prod | Backend·업무 DB·AI·공통 리소스 |
| observability-* | observability.yaml·tempo.yaml의 chart + Git sources | 환경당 관측성 Application 10개, 최초 수동 sync |

외부 chart Helm Application은 multi-source의 `$values`로 현재 저장소 values를 사용한다.
CNPG releaseName은 cloudnative-pg로 유지한다. 이 이름은 기존 NetworkPolicy의 Operator 라벨과 연결된다.
기존 수동 Helm 설치가 있다면 같은 리소스를 Helm과 Argo CD가 동시에 관리하지 않도록 인계·diff를 먼저 확인한다.

## 기존 Controller와 충돌 방지

- Rollout/backend의 `/spec/replicas`는 HPA가 소유한다.
- backend-active/preview의 `rollouts-pod-template-hash` selector는 Rollouts가 소유한다.
- 위 경로만 ignoreDifferences로 지정하고 RespectIgnoreDifferences=true를 사용한다.
- 최초 생성 시에는 Git의 replicas=2가 적용된다. 이후 replica 조정은 HPA min/max로 관리한다.
- annotation 기반 tracking을 사용해 chart와 앱의 instance 라벨을 바꾸지 않는다.
- shared resource 소유 충돌은 FailOnSharedResource=true로 실패시킨다.

## 삭제 정책

workloads는 prune=true, allowEmpty=false, PruneLast=true를 사용한다.
Namespace, StorageClass, 업무 CNPG Cluster, AI DB StatefulSet에는 Prune=confirm,Delete=confirm을 추가한다.
Git에서 실수로 DB 선언을 지워도 자동 삭제하지 않으며 확인 대기 상태를 운영자가 조사한다.
PVC는 StatefulSet 보존 정책과 StorageClass Retain을 별도로 유지한다. 이것은 백업이 아니다.

Platform은 CRD 제거가 모든 하위 리소스에 영향을 주므로 자동 prune을 끈다. 제거는 사용 리소스·백업을 확인한 별도 작업이다.
Application에는 cascading deletion finalizer를 넣지 않는다. Application 삭제만으로 워크로드가 삭제되지 않는다.
Application 수동 삭제 시 orphan 리소스·관리 중단을 반드시 확인한다.
Namespace/StorageClass를 다른 도구가 이미 관리 중이라면 첫 sync 전에 소유권을 조정한다.
보호 component는 현재 보호 대상에 annotations가 없다는 기준이다. 향후 annotation 추가 시 기존 키를 보존하도록 patch도 함께 변경한다.

## 최초 설치 순서

1. 환경 context, EKS와 System/App/DB/GPU 노드 준비 상태를 확인한다.
2. EBS CSI·NetworkPolicy enforcement 등 외부 플랫폼 의존성을 준비한다.
3. `platform/argocd/README.md`대로 Argo CD를 설치하고 read-only Git credential을 등록한다.
4. **선택한 환경의 projects.yaml만** 먼저 적용한다.
5. 해당 환경 platform.yaml을 적용하고 세 Application이 Synced/Healthy가 될 때까지 확인한다. CRD Established와 Controller/DaemonSet 준비도 함께 확인한다.
6. [클러스터 애드온 설치 안내](../platform/cluster-addons.md)에 따라 기존 cert-manager를 먼저 Sync하고, `cluster-addons.yaml`의 Metrics Server·ALB Controller를 등록·수동 Sync한다. ALB의 실제 VPC ID·IRSA를 먼저 반영한다. GPU 노드 준비 후 같은 안내의 NVIDIA Device Plugin을 수동 Sync하고 GPU 등록을 확인한다.
7. 실제 이미지 digest, Backend IRSA·SSM, DB Secrets, AI 모델 설정·용량을 확인한다. 이전 작업의 협업 대기 항목이 남아 있으면 중단한다.
8. 해당 환경 workloads.yaml을 적용한다. ALB Controller·TGB CRD 준비 후 별도 backend-networking Application을 Sync한다.

예시 (Stage 운영자 절차, 이번 작업에서 실행하지 않음):

```bash
kubectl --context '<Stage context>' apply -f argocd/applications/stage/projects.yaml
kubectl --context '<Stage context>' apply -f argocd/applications/stage/platform.yaml
# 해당 Stage Argo CD에 로그인한 상태에서 실행
argocd app wait stage-cloudnative-pg --sync --health --timeout 600
argocd app wait stage-argo-rollouts --sync --health --timeout 600
argocd app wait stage-secrets-store-csi --sync --health --timeout 600
# platform/cluster-addons.md의 cert-manager → Metrics Server/ALB Controller 절차를 완료한다.
# 협업 인계와 모든 배포 조건을 확인한 뒤에만 실행
kubectl --context '<Stage context>' apply -f argocd/applications/stage/workloads.yaml
```

전체 디렉터리 kustomization은 검증·조회용으로 제공한다. 처음부터 전체를 한번에 apply하면 플랫폼 준비 전 워크로드가 먼저 동기화될 수 있다.
별도 Application 사이의 생성 순서를 sync-wave만으로 보장한다고 가정하지 않는다.

## 배포·승격·롤백

1. 이미지 발행 후 실제 ECR digest를 Stage overlay에 반영하는 PR을 검토·merge한다.
2. Argo CD가 반영한 Git revision과 이미지 digest를 확인한다.
3. Backend 새 Preview의 readiness·기능·ALB 상태를 검증한다.
4. 인증된 운영자가 `kubectl --context '<대상 context>' argo rollouts promote backend -n app`으로 트래픽을 전환한다.
5. Stage에서 검증한 동일 digest를 Prod overlay에 넣는 PR을 승인·merge한다. Prod에서도 Preview 확인과 승격을 별도로 수행한다.
6. AI Deployment는 Recreate이므로 Backend와 달리 수동 Rollout 승격 단계가 없고 sync 시 교체·중단이 발생할 수 있다.

승격 전 실패: Preview를 승격하지 않고 필요 시 Rollout abort 후 Git의 잘못된 변경을 수정/revert한다.
승격 후 실패: 이전 검증 digest로 되돌리는 PR을 승인·merge하고 복구 Preview의 상태와 승격 필요 여부를 확인한다.
Git rollback은 DB migration을 되돌리지 않는다. 파괴적 schema 변경은 별도 복구 계획이 필요하다.
Argo CD sync 실패가 전체 트랜잭션 rollback을 뜻하지 않는다. 일부 리소스 반영 여부를 확인한다.
selfHeal이 켜져 있으므로 긴급 kubectl 변경만 남기지 말고 Git desired state도 맞춘다.

## 검증과 한계

`bash scripts/validate-k8s.sh`는 기존 워크로드/정책/차트와 Argo CD chart 및 양쪽 Application을 렌더링한다.
`validate-gitops.rb`는 환경 경로·AppProject 허용 범위·HPA/Service selector 예외·DB 삭제 보호·System 노드 배치를 검증한다.
이 검증은 EKS 접속 없이 실행되며 Argo CD 실제 reconcile을 검증한 것은 아니다.

EKS 검증 체크리스트:
- [ ] 올바른 환경만 등록되고 다른 환경 리소스를 소유하지 않음
- [ ] 플랫폼 CRD/Controller 준비 후 workloads 등록
- [ ] Git revision 변화가 Preview에 반영됨
- [ ] HPA replica 수와 Service hash selector가 selfHeal로 되돌아가지 않음
- [ ] 안전한 테스트 리소스로 drift 복구·prune 확인
- [ ] DB/Namespace 삭제 변경은 confirm 대기임을 테스트 환경에서 확인
- [ ] Preview 검증·promote·실패 시 Git rollback 확인
- [ ] ALB 전환 중 5xx와 SSE 연결 종료 영향 확인

SSO, 원격 Git 자격증명 공급, branch protection/reviewer 설정은 실제 계정 인계가 필요하다.
관측성의 Application·대시보드·로그 설정 연결과 설치 순서는 [관측성 GitOps 안내](../platform/observability/README.md)를 따른다. 이미지 빌드·자동 Promotion PR 생성·Ingress·실제 EKS 검증은 별도다.

참고: [Argo CD sync options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/),
[자동 동기화](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).

### 2026-09-16 로컬 검증 결과

- Argo CD chart 10.9.1과 기존 3개 chart lint/render 통과.
- Stage·Prod별 AppProject/Application, overlay, 보호 정책 계약 검증 통과.
- 임시 렌더링 복사본에서 잘못된 환경 경로, HPA 예외 누락, RespectIgnoreDifferences 누락을 각각 실패로 검출.
- 원본 설정으로 복원한 뒤 동일 검증 통과.
- 검증 CLI 도움말·잘못된 옵션(exit 2), Bash/Ruby 문법 및 git diff --check 통과.
- AWS/EKS 변경, Argo CD 실제 sync, 커밋·push는 수행하지 않음.

### AI 벡터DB 비밀번호 파일 연결

Stage·Prod는 Parameter Store → CSI 파일 마운트를 사용하며 Kubernetes Secret 동기화는 비활성화한다.
DB는 `POSTGRES_PASSWORD_FILE`, 앱 계정 초기화 스크립트는 `AI_DB_PASSWORD_FILE`을 읽는다.
AI는 앱 비밀번호만 별도로 마운트하고 `DB_PASSWORD_FILE`로 경로를 전달받는다.
실제 환경별 IRSA ARN, SSM 파라미터와 **DB_PASSWORD_FILE 지원 AI 이미지**가 준비되기 전에는 배포하지 않는다.
[AI Secret 인계·운영 절차](../k8s/components/ai-vector-db-secrets/README.md)를 따른다.
로컬 Helm/Kustomize 및 Secret 경로·키·마운트 계약 검증은 통과했으며 실제 EKS 검증은 미실시다.

## CNPG 백업 Application — 2026-09-18

각 환경의 `backup.yaml`에 `cert-manager`, `barman-cloud`, `cnpg-backup` Application을 추가했다. 세 Application은 모두 수동 Sync다. 기존 workloads가 CNPG Cluster 소유권을 유지하며 backup chart는 Cluster를 중복 생성하지 않는다. cert-manager 기존 설치가 있으면 재사용 여부를 먼저 확인한다.

의존 플랫폼 설치 → 실제 버킷 입력 후 ObjectStore 생성(정기 백업 suspend 유지) → workloads의 실제 IRSA/WAL component 반영 → 수동 백업·복원 시험 → 정기 백업 활성화 순서다. 자세한 입력과 명령은 [백업 운영 문서](../platform/cnpg-backup/README.md)를 따른다.
