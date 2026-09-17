# AI 벡터DB 파일 기반 비밀번호 공급

Parameter Store → CSI 파일 마운트 → 프로세스가 파일 읽기 방식이다. Kubernetes Secret을 생성하지 않는다. Backend configtree도 유지한다.

## 연결

- 벡터DB: ai-vector-db-sa → ai-vector-db-config → 관리자/앱 비밀번호 파일 두 개.
- 관리자: POSTGRES_PASSWORD_FILE로 PostgreSQL entrypoint가 읽는다.
- 앱 계정 초기화: 비실행 00-load-password.sh를 entrypoint가 source하고, 파일 내용을 프로세스 환경변수 AI_DB_PASSWORD에만 담아 init.sql의 psql 변수 인용으로 전달한다. SQL/명령행 인자에 비밀번호를 직접 삽입하지 않는다.
- AI: ai-worker-sa → ai-chatbot-config → 앱 비밀번호 파일 하나. DB_PASSWORD_FILE로 경로를 전달한다. 관리자 파일은 AI에 마운트하지 않는다.
- init 스크립트는 빈 데이터 디렉터리의 최초 초기화에만 실행된다. ConfigMap 기본 파일 모드 0644를 유지한다.

## 배포 전 필수 조건

- TODO(AI): DB_PASSWORD_FILE을 읽고 파일 누락/빈 값에서 실패하는 AI 이미지/digest 제공. 현재 확인한 AI 코드는 DB_PASSWORD 환경변수만 읽는다. 이 이미지가 준비되지 않으면 배포하지 않는다.
- TODO(인프라): 제안 경로 /staging/ai/vector-db/{postgres-password,password}, /prod/ai/vector-db/{postgres-password,password}를 실제 팀 규칙에 맞춰 확정하고 SecureString 생성. 검증 스크립트도 함께 변경한다.
- TODO(인프라/네이티브): 환경별 ai-vector-db-sa Role ARN을 overlay에 연결한다. 신뢰 sub는 system:serviceaccount:ai:ai-vector-db-sa, audience sts.amazonaws.com. 해당 파라미터의 ssm:GetParameters와 필요한 KMS decrypt만 부여한다.
- ai-worker-sa의 기존 IRSA에 앱 비밀번호 조회 권한을 추가한다. 이 SA는 두 AI Deployment가 공유하므로 권한은 SGLang에도 적용된다. 관리자 비밀번호 조회는 허용하지 않는다. 엄격한 앱별 권한 분리는 별도 SA/Role 합의가 필요하다.
- CSI는 tokenRequests를 사용한다. DB의 일반 API 토큰 automount=false를 유지한다. Driver에 통합 AWS Role을 주지 않는다.
- Driver/Provider 노드 경로의 STS/SSM 연결을 확인한다. DB 컨테이너 egress를 임의 개방하지 않는다.

## 전환과 운영

secretObjects와 ai-vector-db-auth 참조를 제거했다. CSI syncSecret도 false다. 실제 클러스터의 기존 Secret은 소비자가 없는 것을 확인한 후 운영자가 정리한다. 이번 작업은 클러스터 리소스를 삭제하지 않는다.

자동 rotation은 비활성이다. 파일 변경만으로 기존 DB 계정 암호가 바뀌지 않는다. DB 계정 변경, SSM 값 변경, 마운트 갱신, AI 재시작을 유지보수 계획 아래 조정한다. 환경변수·메모리에 암호가 일시적으로 존재할 수 있으며 '파일 방식'을 프로세스에 암호가 없다는 뜻으로 해석하지 않는다.

## 검증

로컬: overlay 렌더링, Secret 복제/참조 제거, DB/AI 파일 경로, AI 관리자 파일 미노출 확인.
DB 이미지: 임시 테스트 비밀번호 파일로 초기화·앱 계정 접속·특수문자 비밀번호·빈 파일 실패·데이터 재사용 확인.
실제 EKS와 실제 AI 이미지는 별도 검증이다. 실제 암호/Secret 내용을 출력하지 않는다.

2026-09-17 로컬 검증 통과: pgvector:0.8.2-pg17-bookworm에서 0644 초기화 파일로 계정 생성, 특수문자 암호 로그인, 잘못된 암호 거부, 빈/누락 파일 거부, 기존 데이터 재시작을 확인했다. TCP 인증 테스트는 initdb의 host 인증을 scram-sha-256으로 명시했다. Mac bind mount의 실행 권한 판정 차이를 피하기 위해 초기화 파일을 컨테이너 내부에 복사하여 ConfigMap 기본 권한을 재현했다. CSI/IRSA 자체의 실행 검증은 포함하지 않는다.
