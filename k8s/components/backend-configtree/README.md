# Backend Parameter Store → CSI → configtree

## 기준과 적용 상태

Backend `develop`의 `0e7a1a0` 실행 설정과 대조한 구성이다.
Stage·Prod 모두 Spring `prod` 프로필을 사용하고 SSM 경로로 환경을 분리한다.
overlay `stage`의 AWS 경로 접두사는 `/staging`, `prod`는 `/prod`다.
Terraform·Backend 소스는 변경하지 않는다. 실제 SSM 값·IRSA·이미지 발행·EKS 기동은 별도 검증 대상이다.

## 동작 순서

1. 인프라 담당자가 SSM에 실제 값을 등록한다. 비밀번호·토큰은 SecureString으로 관리한다.
2. AWS Provider가 `app/backend-sa`에 연결된 IRSA Role로 파라미터를 조회한다.
3. CSI Driver가 SecretProviderClass `backend-config`의 목록을 `/mnt/secrets-store`에 마운트한다.
4. Spring이 `SPRING_CONFIG_IMPORT=configtree:/mnt/secrets-store/`로 파일명=설정 키, 파일 내용=값을 읽는다.
5. `application.yml`의 `${DB_PASSWORD}` 같은 placeholder가 해당 설정값을 사용한다.

OS 환경변수로 변환하지 않으며 Kubernetes Secret에 복제하지 않는다. `secretObjects`는 사용하지 않는다.
`usePodIdentity: 'false'`는 IRSA 선택이다. 파일은 non-root 앱이 읽을 수 있도록 0444이며 읽기 전용 마운트다.
필수 디렉터리에는 `optional:`을 붙이지 않는다. 파라미터 미등록·권한 부족은 볼륨 마운트를 막을 수 있다.

## 파일 매핑

아래 key는 `/{staging|prod}/backend/` 아래에 등록한다.

| SSM key | 파일명 / Spring 설정 키 |
| --- | --- |
| db-url | DB_URL |
| db-username | DB_USERNAME |
| db-password | DB_PASSWORD |
| redis-password | spring.data.redis.password |
| jwt-secret | JWT_SECRET |
| kakao-client-id | KAKAO_CLIENT_ID |
| kakao-client-secret | KAKAO_CLIENT_SECRET |
| naver-client-id | NAVER_CLIENT_ID |
| naver-client-secret | NAVER_CLIENT_SECRET |
| mail-host | MAIL_HOST |
| mail-username | MAIL_USERNAME |
| mail-password | MAIL_PASSWORD |
| mail-from | MAIL_FROM |
| oauth-frontend-redirect-url | OAUTH_FRONTEND_REDIRECT_URL |
| image-base-url | IMAGE_BASE_URL |
| image-upload-bucket | IMAGE_UPLOAD_BUCKET |
| image-return-bucket | IMAGE_RETURN_BUCKET |
| email-verification-url | EMAIL_VERIFICATION_URL |
| email-verification-success-redirect | EMAIL_VERIFICATION_SUCCESS_REDIRECT |
| backend-auth-token | BACKEND_AUTH_TOKEN |

`IMAGE_RETURN_BUCKET`은 비공개 반품 이미지 버킷이다. 주소·버킷명은 일반 String으로 관리할 수 있다.

AI 요청 인증은 `/{staging|prod}/ai/internal-auth-token`을 `AI_INTERNAL_AUTH_TOKEN`으로 마운트한다.
AI의 SecretProviderClass와 같은 파라미터를 사용한다. Backend IRSA에도 이 경로의 조회 권한이 필요하다.
Backend → AI는 `AI_INTERNAL_AUTH_TOKEN`, AI → Backend 콜백은 `BACKEND_AUTH_TOKEN`을 사용한다.

`REDIS_HOST`, `REDIS_PORT`, `AI_CHAT_BOT_URL`, `AI_CONTENT_URL`은 base Rollout의 내부 Service 주소 설정을 사용한다.
사용하지 않는 `AI_BASE_URL`은 조회 목록에서 제외했다. 실제 AWS 파라미터를 삭제하는 변경은 아니다.
Redis 비밀번호는 Redis 서버와 동일 파라미터를 읽는다. OAuth는 현재 Backend 코드의 Kakao·Naver 설정과 일치한다.
SMTP 587, 이메일 TTL 1800초 등 기본값이 있는 선택 항목은 필요할 때만 별도 공급한다.
결제·택배 기능을 사용할 때는 Backend의 TOSS/SWEET_TRACKER 설정과 실제 자격증명도 별도로 준비한다.

## 배포 전 인계값

- 환경별 Backend IRSA ARN: overlay에서 `backend-sa`에 `eks.amazonaws.com/role-arn` annotation을 추가한다.
  현재 실제 ARN은 선언하지 않았다. Trust의 sub는 `system:serviceaccount:app:backend-sa`, aud는 `sts.amazonaws.com`이며 대상 EKS OIDC와 연결한다.
- Role 권한: 위 SSM 파라미터 조회, 사용하는 KMS 키의 필요한 복호화 권한, Backend 이미지 버킷 접근.
  Role 권한과 별도로 STS·SSM·S3 통신 경로도 준비한다.
- DB 값은 CNPG 앱 계정과 일치해야 한다. JDBC 주소는
  `jdbc:postgresql://jangingmall-postgres-rw.database.svc.cluster.local:5432/jangingmall`이다.
- 이메일 인증·프론트 리다이렉트 URL과 이미지 URL·버킷명을 환경별로 확정한다.
- 새 매핑을 적용하기 전에 실제 SSM 파라미터를 등록한다. 기존 파일 존재만으로 값의 정확성을 보장하지 않는다.

## 이미지 발행과 GitOps 연결

Backend `cd.yml`은 develop push에서 테스트 → 빌드 → OIDC 인증 → ECR 발행을 수행한다.
Backend 저장소 Actions Variables는 `AWS_REGION=ap-northeast-2`, `ECR_REPOSITORY=jangin-app`, 실제 `AWS_ROLE_ARN`이다.
이 GitHub Actions Role은 Pod의 IRSA Role과 별개다. 현재 workflow의 `latest` 덮어쓰기와 ECR 태그 변경 정책이 호환되는지도 확인한다.

1. Backend Actions의 `Print image digest` 로그에서 `Full ref`를 확인한다.
2. Stage `kustomization.yaml`에 실제 ECR URI와 digest를 `images`로 지정하는 infra PR을 만든다.
3. Stage 검증 후 동일 digest를 Prod overlay에 반영한다. release에서 이미지를 재빌드하지 않는다.

```yaml
# 실제 값 수령 후 해당 환경의 kustomization.yaml에 추가하는 형식 예시다.
images:
  - name: jangin-app
    newName: <ECR registry>/jangin-app
    digest: sha256:<실제 digest>
```

Stage·Prod workloads Application은 현재 자동 Sync다. 기존 버전 업데이트 시 Preview 검증 후 수동 Promote한다.
SecretProviderClass만 바꾸면 Rollout Pod가 자동 재생성되는 것은 아니다.
현재 CSI 자동 rotation은 비활성이고 JVM 자동 재로딩도 구성하지 않았다.
설정 변경은 리소스 적용 후 관리된 Pod 재생성과 앱 검증까지 수행한다.
Blue/Green 용량 제약은 [Backend 자원 문서](../../base/backend/README.md)를 따른다.

## 검증

로컬에서는 두 overlay 렌더링과 SSM 경로·alias·AI 공유 토큰·configtree 연결을 확인한다.
전체 저장소 검증 명령은 `bash scripts/validate-k8s.sh`이며 Helm chart 다운로드 등 추가 도구·네트워크가 필요하다.

EKS에서는 다음 순서로 확인한다.

1. CSI/Provider 및 IRSA, SSM 등록·접근 경로 준비.
2. Pod 볼륨 마운트와 Spring prod 기동 확인.
3. DB 연결·Flyway, Redis 사용 기능 확인.
4. 9090의 liveness/readiness 및 Prometheus 응답 확인.
5. Preview에서 이미지 업로드·이메일 인증·AI 호출을 해당 외부 서비스 준비 후 검증.
6. 검증 후 Promote하고 Active 동작 확인.

비밀값을 cat·전체 env·로그로 출력하지 않는다. 파일 존재·읽기 권한과 기능으로 확인한다.
로컬 렌더링 통과는 실제 AWS 권한·전체 앱 기동·EKS 통신 성공을 뜻하지 않는다.
