# 워크로드 SSM·IRSA 연결

## 구현 범위

Stage·Prod에서 Kubernetes의 CSI 파일 마운트에 필요한 파라미터 이름과 IAM 권한을 맞춘다.
코드 준비와 로컬 검증 범위이며 AWS 프로비저닝·실제 값 입력·EKS 배포 완료를 뜻하지 않는다.

| Terraform 환경 | Kubernetes overlay | SSM 접두사 |
| --- | --- | --- |
| staging | stage | `/staging/` |
| prod | prod | `/prod/` |

Backend·AI 담당자가 AWS 콘솔/CLI로 Parameter Store 값을 직접 등록·갱신한다.
애플리케이션이 파라미터를 생성하는 방식이 아니며, Pod는 기존 CSI·IRSA로 값을 읽는다.

각 환경의 `terraform.tfvars.example`에는 Backend 20개·AI 3개 등록 목록을 **주석**으로 보관한다.
`ssm.tf`의 생성 리소스와 `variables.tf`의 두 입력 변수도 삭제하지 않고 주석 처리한다.
이 블록들은 Terraform에서 실행되지 않는다. 실제 값을 예시 파일·`terraform.tfvars`·Git에 입력하지 않는다.
주석의 `CHANGEME`는 미입력 표시이며, 직접 등록한 실제 값은 Terraform 변수 검증 대상이 아니다.

## 직접 등록 기준과 담당

| 항목 | 기준 |
| --- | --- |
| 이름 | 주석 목록의 키에 `/<env>/backend/` 또는 `/<env>/ai/`를 붙인다. `db-password`와 `db_password`는 서로 다른 이름이다. |
| 타입·계층 | `SecureString`·Standard |
| 암호화 키 | 해당 환경의 `module.kms_app.key_arn`에 해당하는 실제 CMK ARN. 인프라 담당자가 제공한다. |
| 등록 위치 | 해당 환경 IRSA와 같은 AWS 계정·리전 |
| 소비 경로 | `k8s/overlays/{stage,prod}/*-secret-provider.yaml`의 `objectName`과 일치 |

| 담당 | 역할 |
| --- | --- |
| 인프라 | KMS·IRSA 프로비저닝, 실제 CMK·Role ARN 제공, 등록 담당자의 환경·경로별 쓰기 권한 설정 |
| Backend | `/backend/`의 설정값 등록·갱신. DB/Redis 비밀번호는 해당 운영 담당자와 일치시킨다. |
| AI | `/ai/internal-auth-token` 등록·갱신. 벡터DB 앱 비밀번호는 DB 운영 담당자와 조율한다. |
| DB 운영 담당 | `/ai/vector-db/password`, `/ai/vector-db/postgres-password` 등록 및 실제 DB 계정과 일치 유지 |
| 네이티브 | 파라미터 이름·CSI 매핑 유지, 실제 IRSA ARN 연결, 마운트·연결 검증 |

등록자 권한은 사람의 IAM/SSO 역할에 부여한다. Pod IRSA에 `ssm:PutParameter`를 추가하지 않는다.
공유 토큰은 위 담당자가 한 경로에 등록하고 양쪽 앱이 같은 파라미터를 읽는다.
KMS와 등록자 권한이 준비되면 EKS 기동 전에도 등록할 수 있다.
현재 변경에는 실제 AWS 권한 부여·값 등록이 포함되지 않는다.

이 변경은 아직 파라미터를 Terraform으로 적용하지 않았다는 전제다.
이미 state에 등록된 환경에서는 주석 처리만으로 다음 apply 때 삭제 대상이 될 수 있으므로,
실제 값을 유지하는 state 관리 해제 절차를 먼저 수행해야 한다.

## 권한과 소비자

아래 `<env>`는 `staging` 또는 `prod`다. SSM 권한의 리전·계정은 해당 Terraform 환경에서 결정한다.

| Role output 키 | 신뢰하는 ServiceAccount | SSM 조회 범위 |
| --- | --- | --- |
| `backend` | `app/backend-sa` | `/<env>/backend/*`, `/<env>/ai/internal-auth-token` |
| `ai` | `ai/ai-worker-sa` | AI 요청 토큰, Backend 콜백 토큰, 벡터DB 앱 비밀번호 |
| `redis` | `app/redis-sa` | `/<env>/backend/redis-password` |
| `ai-vector-db` | `ai/ai-vector-db-sa` | `/<env>/ai/vector-db/password`, `/<env>/ai/vector-db/postgres-password` |

CSI 조회에는 `ssm:GetParameters`를 허용한다. 새 Redis·벡터DB Role은 위 파라미터 조회와
`module.kms_app.key_arn` 복호화만 허용하며, `kms:ViaService`를 해당 리전의 SSM으로 제한한다.
Backend·AI의 기존 S3·KMS 권한은 유지한다. AI의 `/ai/*` 권한은 필요한 세 경로로 좁힌다.
두 AI Deployment가 `ai-worker-sa`를 공유하므로 앱 토큰·앱 DB 비밀번호 권한도 공유한다.
벡터DB 관리자 비밀번호는 그 공유 Role의 조회 대상에서 제외한다.

## 값이 일치해야 하는 연결

- Backend `db-password`: CNPG `jangingmall-postgres-app` Secret의 `jangingmall` 계정 비밀번호와 동일해야 한다.
- Backend JDBC 주소: `jdbc:postgresql://jangingmall-postgres-rw.database.svc.cluster.local:5432/jangingmall`.
- Redis 비밀번호: Backend와 Redis가 같은 파라미터를 읽는다. 현재 Redis 시작 스크립트는 64자리 16진수를 요구한다.
- `/<env>/ai/internal-auth-token`: Backend → 상세페이지 AI 요청 인증에 양쪽이 함께 사용한다.
- `/<env>/backend/backend-auth-token`: 상세페이지 AI → Backend 콜백 인증에 양쪽이 함께 사용한다. 요청 토큰과 별도 값이다.
- 벡터DB 앱 비밀번호: 챗봇 API와 DB 초기화가 같은 파라미터를 사용한다. 관리자 비밀번호는 별도 값이다.
- SSM 값 변경만으로 기존 PostgreSQL 계정 비밀번호가 변경되지 않는다. DB 계정 변경과 앱 재시작을 조율한다.
- 현재 매핑은 결제·배송 조회 API 키를 포함하지 않는다. 해당 기능 사용 시 Backend의 TOSS/SWEET_TRACKER 키와 CSI 매핑을 추가한다.

## 로컬 검증

Terraform 1.5 이상과 잠긴 provider 버전, Ruby, kubectl이 필요하다. 아래 명령은 `infra` 루트에서 실행한다.

```bash
ruby scripts/validate-workload-secrets.rb
terraform -chdir=terraform/environments/staging init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform/environments/staging validate
terraform -chdir=terraform/environments/prod init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform/environments/prod validate
```

`init -backend=false`는 원격 state에 연결하지 않고 검증용 모듈·provider를 준비한다.
provider 다운로드에는 인터넷이 필요하지만 위 검증에 AWS 자격증명이나 기존 EKS는 필요하지 않다.
정적 계약 검사는 두 overlay를 렌더링해 주석의 등록 목록·SSM 이름·CSI 소비 ServiceAccount·Role 연결·SSM/KMS 범위를 대조한다.
`ssm.tf`와 입력 예시가 비활성화된 상태인지도 확인한다.
실제 IAM 평가나 CSI 인증 성공을 보장하는 검사는 아니다. `plan`·`apply`는 이 로컬 검증에 포함하지 않는다.

## 프로비저닝 후 인계

1. 인프라 담당자가 KMS·IRSA를 프로비저닝하고, 등록 담당자에게 해당 환경 CMK ARN과 쓰기 권한을 제공한다.
2. Backend·AI·DB 운영 담당자가 위 기준대로 값을 직접 등록하고 파라미터 이름과 등록 완료 여부를 공유한다. 비밀값 원문을 전달할 필요는 없다.
3. 인프라 담당자가 환경별 `terraform output -json irsa_role_arns`의 `backend`, `ai`, `redis`, `ai-vector-db` ARN을 전달한다.
4. 네이티브가 각 환경 overlay의 해당 ServiceAccount에 `eks.amazonaws.com/role-arn` annotation을 추가한다.
5. SSM·STS 통신 경로와 CSI 플랫폼 구성이 준비된 EKS에서 파일 마운트·앱 시작·DB/Redis/AI 인증 연결을 검증한다.

현재 Kubernetes에 실제 ARN은 주입하지 않는다. 파라미터 등록·권한 적용·ARN 연결 전에 워크로드 Sync를 진행하지 않는다.
