# CI/CD 참조 초안 — T-20260915-CICD v2 + T-20260915-CICD-GITOPS v1

가정: staging 소스 브랜치는 현행 dev를 유지한다. dev/develop 최종 선택은 BE 확정 의존성이다.
수동 승격 워크플로 실행 브랜치는 현행 main을 유지한다.
최종 설치 위치는 BE 앱 레포의 .github/workflows/이며, 현재 infra/ci-cd에서는 실행되지 않는다.
기준 infra SHA: affebc2bd80ae4641a8276cbe6a284c66a40f104.

## 동작과 미연결 지점

- feature/* → dev PR: ci job에서 BE 테스트 후 Docker 빌드. AWS 인증과 ECR push 없음.
  dev를 대상으로 하는 모든 PR을 검사하므로 다른 이름의 소스 브랜치도 검증된다.
- dev push: SHA 앞 7자리를 조회한다. 기존 이미지면 빌드·테스트·push를 건너뛰고 digest를 재사용한다.
  ImageNotFound만 새 빌드를 허용한다. API 실패, 권한 오류, 예상 밖 응답은 실패한다.
- 새 이미지: BE 테스트 → Docker 빌드 1회/push → 반환된 digest 사용. latest/env 접두사 없음.
- staging: 설정이 있으면 GitOps 체크아웃의 overlay를 jangin-app=<registry>/<repo>@sha256:<digest>로 편집·렌더한다.
- prod: main에서 SHA를 입력해 수동 실행한다. prod Environment 승인 후 staging 검증 기록과 대조하고
  ECR describe-images로 얻은 동일 digest를 prod overlay에 고정한다. 빌드·push 없음.
- GitOps 대상 제안은 아래 계약표와 같다. 실제 overlay는 미구현이며, GitOps Variables 미설정 시 해당 checkout/편집 step은 명시적으로 skip한다.
  설정되어도 runner 안에서만 편집하며 Git commit/push, ArgoCD sync, 클러스터 조작은 하지 않는다.
  summary의 digest와 검토한 overlay 변경을 박명수에게 인계한다. 실제 커밋 접점은 회신 후 별도 작업이다.
- staging 검증 성공은 CI push 성공에서 추론하지 않는다. 박명수가 staging sync 및 preview/active 검증을
  마친 후 source SHA·digest·CI run 링크·검증 근거를 기록해야 한다.
- GitHub 승인 = prod 이미지 후보 결정. Rollout 수동 promote = 운영 트래픽 전환.
  워크플로는 Rollout promote/abort/undo를 호출하거나 autoPromotionEnabled를 변경하지 않는다.

## Variables / Secrets 계약

| 이름 | 위치 / 값 | 미확정 동작 |
|---|---|---|
| AWS_REGION | repo Variable, 확정: ap-northeast-2 | 기존 기본값 유지 |
| ECR_REPOSITORY | repo Variable, 창원 확정: jangin-app | 빈 값/CHANGE_ME면 CD·승격 실패, 기본값 추가 없음 |
| AWS_ROLE_ARN | repo Variable: dev push 역할 | 빈 값/CHANGE_ME면 CD 실패 |
| AWS_ROLE_ARN | prod Environment Variable: 승격 전용 읽기 역할로 override | 박다정 확인 전 실행 금지 |
| DOCKERFILE / BUILD_CONTEXT | repo Variable, 기본 Dockerfile / . | BE 회신 후 확정 |
| TEST_COMMAND | repo Variable, BE가 승인한 테스트 명령 | 비어 있으면 PR·새 이미지 CD 실패 |
| GITOPS_REPOSITORY | repo Variable, Jangingmall/infra (저장소 사실, 기획의 Map 인용과 일치) | GitOps 적용은 박명수 확정 대상 제안; 미설정이면 skip |
| GITOPS_REF | repo Variable, main | 창원 기본 제안·박명수 확정 대상; 미설정이면 skip |
| GITOPS_STAGING_PATH | repo Variable, k8s/overlays/staging | 창원 제안·박명수 확정 대상, 미구현; 미설정이면 skip |
| GITOPS_PROD_PATH | repo Variable, k8s/overlays/prod | 창원 제안·박명수 확정 대상, 미구현; 미설정이면 skip |
| ArgoCD Application 경로 | 문서 참조: argocd/applications/{staging,prod} | 박명수 소유·미구현, 박명수 확정 대상 제안; Variable/파일 생성 없음 |
| GITOPS_READ_TOKEN | Actions Secret, GitOps checkout만 가능한 읽기 토큰 | 비공개 레포 checkout 전 필요 |
| STAGING_VERIFIED_SHA | prod Environment Variable, 검증 완료 앱 전체 SHA 40자리 | 없거나 요청 SHA와 다르면 실패 |
| STAGING_VERIFIED_DIGEST | prod Environment Variable, 검증 완료 sha256:64hex | 없거나 ECR과 다르면 실패 |

TEST_COMMAND는 신뢰된 설정 관리자가 지정한다. BE 런타임 버전과 setup step(예: JDK)은 미확정이다.
필요한 setup은 최종 설치 전 확정하며, fork PR에 쓰기 토큰이나 AWS 권한을 제공하지 않는다.
GitOps 편집 step을 활성화하기 전 runner에 팀이 승인한 버전의 kustomize를 설치해야 한다.

STAGING_VERIFIED_*는 자동 배포 증명이 아니라 운영자가 남기는 임시 수동 검증 기록이다.
박명수가 동일 검증 건의 SHA/digest를 함께 갱신하고 prod 승인자가 run 근거와 대조한다.
승격은 현재 기록된 한 이미지에 대해서만 허용된다. 이 기록 변경 권한도 제한해야 한다.
후속 연동에서는 staging 검증 결과를 신뢰할 수 있는 불변 산출물로 전달하는 계약이 필요하다.

## GitOps 인계 제안과 회신 의존성 — T-20260915-CICD-GITOPS v1

근거: 2026-09-15 기획서의 Cloud Native Runtime Resource Map v0.1 인용과 infra main@affebc2.
Runtime Map 원본은 이번 세션에서 찾지 못했으며, Map 관련 내용은 기획서 인용을 기준으로 한다.
현재 코드에서 ECR jangin-app, Terraform env staging, overlay 미존재 및 argocd README 스텁을 확인했다.
대상 저장소 Jangingmall/infra의 존재와 GitOps 경로·운영 방식의 확정 여부는 구분한다.

창원 제안: 최종 워크플로가 있는 BE 앱 레포에서 Jangingmall/infra로 cross-repo PR을 만들어
overlay 이미지 변경을 인계한다. PR base는 main을 제안하며 main 직접 push는 금지한다.
GitOps PR 방식·커밋 접점·브랜치·overlay/ArgoCD 구조의 확정과 구현은 박명수 소관이다.
승인 후 필요한 쓰기 권한도 대상 infra 레포의 제안 브랜치 변경과 PR 생성에 한정하는 최소권한으로 협의한다.
구체적으로 contents:write와 pull_requests:write를 갖는 대상 레포 한정 자격증명을 제안하며,
승인 전 토큰 발급·권한 확대·PR 자동화는 수행하지 않는다. 현행 GITOPS_READ_TOKEN과 workflow permissions는 유지한다.

현재 k8s/overlays/와 ArgoCD Application은 미구현이다. 경로 제안만으로 Variables를 활성화하지 않는다.
박명수의 대상 생성·확정 후 별도 작업에서 연결한다. 현행 workflow는 설정 미입력 시 인계 step을 skip하고,
설정 시에도 runner 체크아웃 편집/렌더까지만 수행한다. 실제 PR·커밋·push·ArgoCD sync는 미연결이다.

overlay 이름은 Terraform env와 tfstate의 staging 표기에 맞춰 k8s/overlays/staging으로 통일할 것을 제안한다.[^map-stage]
최종 네이밍은 팀/박명수 확정 대상이며 실제 디렉터리를 만들거나 이름을 바꾸지 않는다.

태그 형식은 terraform/environments/{staging,prod}/ecr_variables.tf의 blocker #2가 미정이다.
현행 ${GITHUB_SHA::7}(접두사 없는 SHA 7자리)과 promote의 SHA 처리 로직을 그대로 유지한다.
이번 문서는 팀 태그 규칙을 확정하지 않는다. blocker 해소 후 형식 변경은 별도 작업으로 한다.

| 회신 주체 | 미결 항목 | 이번 처리 |
|---|---|---|
| 박명수 | GitOps 경로·overlay/ArgoCD 생성·커밋 접점·PR 방식 | 제안/인계만, 구현·활성화 보류 |
| BE(박다정·박명수 경유) | dev/develop, Dockerfile·테스트 명령 | 현행 dev 트리거·기본값·로직 유지 |
| 박다정 | CI용 AWS_ROLE_ARN·OIDC trust | 미결 유지; Map §10의 jangin-{env}-irsa-*는 Pod용으로 CI 재사용 금지 |
| 팀/박명수 | overlay 최종 네이밍 | staging 통일 제안 |
| 팀 | 태그 blocker #2 | SHA7 무변경, 결정 후 별도 작업 |

[^map-stage]: 기획서에 인용된 Runtime Map의 overlays/stage 표기는 Terraform env·tfstate staging과 불일치하여 정정 대상으로 제안한다. Map 원본 자체는 수정하지 않았다.

## prod 승인 설정 — 설치 전 필수

prod Environment를 미리 만들고 Required reviewers, Prevent self-review를 설정한다.
관리자 우회는 차단하고 배포 브랜치는 main만 허용한다. main/dev 보호 및 ci required check도 설정한다.
워크플로의 environment: prod 선언만으로 승인 요구가 생기지 않는다.
현재 저장소 플랜/공개 범위에서 Required reviewers를 지원하는지 승인자 소유자와 확인한다.
필수 보호규칙을 구성할 수 없으면 prod 워크플로를 활성화하지 않는다.
참고: [GitHub Environment 보호규칙](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

## 박다정 OIDC / ECR 최소권한 요청서 (AC-07)

앱 레포 org/name, AWS 계정 ID, dev/prod 역할 ARN은 회신 필요. IAM Terraform은 작성·수정하지 않는다.
provider = token.actions.githubusercontent.com, audience = sts.amazonaws.com.
신뢰 주체는 다음 정확한 sub로 제한하고 org/repo wildcard는 쓰지 않는다.

| 경로 | 기본 OIDC sub | 요청 권한 |
|---|---|---|
| CI PR | repo:<ORG>/<APP_REPO>:pull_request | AWS 역할 신뢰/권한 불필요. ci는 id-token: write 없음 |
| CD dev push | repo:<ORG>/<APP_REPO>:ref:refs/heads/dev | 단일 ECR 레포 push/조회 |
| prod promote | repo:<ORG>/<APP_REPO>:environment:prod | 단일 ECR 레포 DescribeImages만 |

기획 AC-07의 main ref 예시는 CD=dev 요구와 충돌하므로 실제 트리거 dev를 적용했다.
main에서 실행하는 승격 job은 Environment를 사용하므로 sub가 ref:refs/heads/main이 아니다.
prod의 main 제한은 Environment 배포 브랜치 보호와 job 조건으로 적용한다.
조직에서 OIDC subject를 커스터마이즈했다면 위 기본형과 실제 claims를 대조한 뒤 trust를 확정한다.
참고: [GitHub OIDC AWS 설정](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).

CD 역할의 repository 리소스는 arn:aws:ecr:ap-northeast-2:<ACCOUNT_ID>:repository/jangin-app 하나로 제한한다.
실제 리전·이름은 합의된 AWS_REGION/ECR_REPOSITORY 값과 일치해야 한다.

- 조회/레이어 확인: ecr:BatchGetImage, ecr:BatchCheckLayerAvailability, ecr:GetDownloadUrlForLayer.
- push: ecr:InitiateLayerUpload, ecr:UploadLayerPart, ecr:CompleteLayerUpload, ecr:PutImage.
- 로그인: ecr:GetAuthorizationToken. 이 액션만 리소스 수준 제한을 지원하지 않아 Resource "*"가 필요하다.
- prod 읽기 역할: 같은 단일 repository ARN의 ecr:DescribeImages만 요청. ECR 로그인/push 권한 불필요.
- 삭제, repository 생성, IAM, S3, EKS, ArgoCD 권한은 요청하지 않는다.

repo Variable과 prod Environment Variable의 AWS_ROLE_ARN을 각각 설정하여 역할을 분리한다.
공용 ECR 소유 state(shared 분리)는 회의 결정 대기이며 이 초안은 Terraform/state를 변경하지 않는다.
참고: [AWS ECR push 권한](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html),
[AWS BatchGetImage](https://docs.aws.amazon.com/cli/latest/reference/ecr/batch-get-image.html).

## 롤백 (AC-08)

1. 운영자가 이전 정상 배포의 앱 전체 SHA·7자리 태그·digest·GitOps 커밋·검증 근거를 선택한다.
2. ECR describe-images로 이전 태그가 아직 존재하고 기록된 digest와 일치하는지 확인한다.
   lifecycle은 최근 10개 유지 기준이며 실행 중 이미지 보호가 아니다. 개수 내 보존을 가정하지 말고 실제 존재를 확인한다.
3. prod overlay의 jangin-app을 이전 <registry>/jangin-app@sha256:<digest>로 되돌리는 최소 변경을 검토한다.
   재빌드·태그 덮어쓰기·재push하지 않는다. 이미지가 삭제되었으면 이 롤백 경로는 진행할 수 없다.
4. prod 이미지 결정 승인을 거쳐 박명수가 합의된 GitOps 커밋 접점으로 반영한다.
   이 초안의 promote를 쓸 경우 이전 이미지의 유효한 staging 검증 근거로 STAGING_VERIFIED_*를 먼저 갱신한다.
5. 박명수가 ArgoCD 동기화·Rollout 상태를 확인하고 별도 수동 promote와 트래픽 검증을 수행한다.
   긴급 Rollout abort/undo도 박명수 소관이며 이 워크플로가 실행하지 않는다.
6. 이전/이후 digest, 승인, GitOps 커밋, 트래픽 검증과 결과를 기록한다.

## AC 검증 접점

| AC | 파일 / job 또는 step |
|---|---|
| 01 | build-deploy.yml / ci: BE 테스트, Docker 빌드 검증 |
| 02 | build-deploy.yml / cd: 이미지 태그 결정, 새 SHA 이미지 빌드 및 push |
| 03 | build-deploy.yml / cd: existing, exists == false 조건 |
| 04 | build-deploy.yml / staging overlay digest 편집 및 렌더 (placeholder 인계점) |
| 05 | promote.yml / promote.environment: prod + 위 필수 외부 보호규칙 |
| 06 | promote.yml / tag, image, prod overlay 동일 digest 편집 및 렌더 (커밋 미연결) |
| 07 | 이 문서 / 박다정 OIDC 요청서 |
| 08 | 이 문서 / 롤백 |
| 09 | 두 워크플로 / 이미지 편집만, Rollout 조작 없음 |

검증: actionlint ci-cd/*.yml. 실제 overlay가 확정되면 두 환경에 kustomize build를 수행한다.
CI run, OIDC, ECR push/재사용, 승인 대기, staging=prod digest, Rollout 트래픽 전환 및 롤백은 실환경 검증 필요.
로컬 PASS는 실배포 성공이 아니다. 현재 결과는 미커밋 참조 초안이며 커밋/push/PR은 수행하지 않는다.

## AC-G 검증 접점

| AC | 파일 / 위치 | 적용 |
|---|---|---|
| AC-G1 | build-deploy.yml / env.ECR_REPOSITORY, promote.yml / env.ECR_REPOSITORY | 확정 주석만 변경 |
| AC-G2 | 이 문서 / Variables 계약표 | 저장소 사실과 박명수 확정 대상 제안 구분 |
| AC-G3 | 이 문서 / GitOps 인계 제안, 두 workflow / GitOps 주석 | cross-repo infra PR·최소권한 제안, runner 편집/렌더 유지 |
| AC-G4 | 이 문서 / overlay 네이밍·map-stage 각주 | staging 통일 제안, 팀/박명수 확정 |
| AC-G5 | 이 문서 / 태그 blocker #2 | SHA7 및 태그 로직 무변경 |
| AC-G6 | .gitignore / !ci-cd/README.md | 예외 1줄 append로 추적 가능화, git add는 미실행 |
| AC-G7 | 이 문서 / 회신 의존성, build-deploy.yml / on | BE 확정 전 dev 유지 |

검증 기준은 main@affebc2 + 이번 작업 시작 시점의 미커밋 ci-cd/ 3파일이다.
주석 변경 전후 YAML 파싱 결과가 동일한지 확인하고 actionlint ci-cd/*.yml로 검증한다.

