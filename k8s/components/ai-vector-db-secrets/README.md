# AI 벡터DB Parameter Store 연결

Stage·Prod overlay에서만 사용한다. Parameter Store → CSI 마운트 → ai-vector-db-auth Secret 동기화 → DB/AI 환경변수 경로다. Backend configtree에는 secretObjects를 추가하지 않는다.

## 배포 전 필수 인계

- 제안 경로는 `/staging/ai/vector-db/{postgres-password,password}`와 `/prod/ai/vector-db/{postgres-password,password}`다. 기존 팀 3단 경로 규칙과 다르므로 실제 이름을 인프라와 확정하고 SPC 및 검증을 함께 갱신한다.
- 두 파라미터는 환경별 SecureString으로 생성한다. 실제 값은 Git에 넣지 않는다.
- 환경별 IRSA Role 신뢰 대상: `system:serviceaccount:ai:ai-vector-db-sa`, audience `sts.amazonaws.com`, 해당 EKS OIDC provider.
- 인프라가 두 파라미터의 ssm:GetParameters와 사용 KMS 키의 필요한 kms:Decrypt 권한을 제공한다.
- 실제 ARN을 받은 뒤 각 환경 overlay에서 ai-vector-db-sa의 `eks.amazonaws.com/role-arn` annotation을 patch한다. 현재 ARN은 미제공이며 이 상태는 배포 준비 완료가 아니다.
- CSI driver/provider의 노드 네트워크에서 STS·SSM 접근이 가능해야 한다. DB 컨테이너의 egress를 임의 개방하지 않는다.

## 인증과 최초 실행

DB의 일반 Kubernetes API 토큰 자동 마운트는 계속 비활성이다. CSI Driver의 tokenRequests(sts.amazonaws.com)로 Pod ServiceAccount 토큰을 요청하는 경로를 사용한다. CSI Driver에 AWS IRSA Role을 부여하지 않는다.

플랫폼 CSI syncSecret/RBAC 준비 후 workloads를 등록한다. DB Pod가 CSI 볼륨을 마운트해야 Secret이 동기화된다. SPC만 적용해도 Secret이 생기는 것은 아니다. 같은 Pod에서 Secret 환경변수를 사용할 때 초기 동기화 동안 컨테이너 생성이 재시도될 수 있다. Ollama도 Secret 준비 전에는 대기할 수 있다.

관리자 비밀번호 파일은 벡터DB Pod에만 마운트한다. Ollama는 기존 password 키 참조를 유지한다. Argo CD가 Secret을 직접 선언하지 않으며 CSI가 소유한다.

## 생명주기와 비밀번호 변경

동기화를 담당하는 마운트 Pod가 모두 삭제되면 동기화 Secret도 삭제될 수 있다. 환경변수 참조만 하는 AI Pod가 Secret을 유지한다고 가정하지 않는다. GPU 노드 재가동 시 SSM/IRSA가 다시 준비되어야 한다. Secret 부재를 빈 비밀번호나 인증 우회로 처리하지 않는다.

자동 rotation은 비활성이다. 기존 PVC의 DB 계정 비밀번호는 SSM 갱신이나 Pod 재시작만으로 변경되지 않는다. 백업/유지보수 계획 하에 DB 계정 암호, SSM 값, Secret 재동기화, AI 재시작을 조정한다. 각 단계의 불일치 기간에는 접속 실패가 가능하며 실제 값을 로그·명령 이력에 남기지 않는다.

## 검증

로컬: overlay 렌더링, 환경별 경로, alias/key, CSI 마운트, Helm sync RBAC를 확인한다.
실제 EKS: ARN·SSM 준비 후 CSI 마운트/Secret 존재와 키 이름만 확인하고 DB Ready, AI 인증 접속, DB Pod 재생성 후 재연결을 확인한다. Secret 값 출력은 하지 않는다. 이 문서는 실제 EKS 검증 결과가 아니다.

공식 근거: https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret
