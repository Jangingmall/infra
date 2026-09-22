# AI 이미지와 모델 배포 연결

## 적용 범위와 현재 상태

이 구성은 infra 저장소에서 관리하는 이미지 복사, 모델 준비, Kubernetes 볼륨 연결이다.
Backend·GenAI 소스는 수정하지 않는다. 모델 버킷은 Terraform Prod에서 관리하고 Stage는 참조한다. 실제 AWS 리소스 생성, 이미지 복사, 모델 업로드, 클러스터 배포는 실행하지 않았다.

| 대상 | 이번 코드의 동작 | 활성화 상태 |
| --- | --- | --- |
| 상세페이지 API | Backend 기본 주소로 callback 전달. AI 코드가 `/internal/generations/{generation_id}/completion`을 붙임 | Base/Stage/Prod 반영 |
| 챗봇 API | `/ai/ready`로 DB·임베딩·LLM 준비 확인, `/ai/health`로 생존 확인. CPU 이미지의 GPU 예약 제거 | Base/Stage/Prod 반영 |
| 모델 저장소 | 상세페이지 100Gi, 챗봇 BGE-M3 10Gi, S3 준비용 initContainer | 선택형 컴포넌트, 두 환경 모두 미활성 |
| 공개 이미지 복사 | 수동 Actions 실행 시 지정한 digest를 ECR로 복사 | workflow 추가, 실제 실행 전 |
| 챗봇 LLM | 사용할 엔진·이미지 digest·모델·실행 명령 확정 필요 | 컨테이너 미구현, 챗봇 답변 생성 배포 완료 아님 |

상세페이지 통합 이미지는 API·텍스트 추론·이미지 추론을 함께 실행한다. 별도 상세페이지 LLM 이미지를 추가하지 않는다.
챗봇의 `jangin-ai/chatbot-api`는 CPU용 API/BGE-M3 이미지다. 이 이미지 자체에 Ollama/SGLang 서버가 들어 있지는 않다.

## 실행 순서

```text
GenAI CI: 소스 테스트 → 상세페이지 이미지/챗봇 API 이미지 → ECR
infra 수동 workflow: 공개 런타임 @digest → 기존 ECR 저장소 (다시 빌드하지 않음)

Kubernetes Pod 생성
  → 노드가 ECR 이미지를 받음
  → PVC 연결
  → initContainer가 IRSA로 S3 모델 파일을 받음
  → SHA256SUMS와 실제 파일 검증
  → 앱 컨테이너 시작
  → readiness 성공 후 Service가 요청 전달
```

이미지 다운로드는 노드의 ECR 접근 경로와 권한을 사용한다. 모델 다운로드는 Pod의 IRSA 및 S3/STS 통신을 사용한다. ECR 이미지를 준비했다고 모델도 포함되는 것은 아니다.

## 먼저 해결할 AI 이미지 계약

현재 GenAI `page_generation/deploy/sglang/entrypoint.sh`의 `validate_local_model`은 TEXT와 IMAGE 모두 루트 `config.json`을 요구한다.
하지만 고정된 FLUX diffusion 저장소에는 루트 `model_index.json`이 있고, 구성 요소별 하위 폴더에 `config.json`이 있다.
**AI팀이 TEXT는 `config.json`, IMAGE는 `model_index.json`을 검사하도록 수정하고 CI로 새 이미지를 발행해야 한다.**
infra에서 가짜 `config.json`을 만들거나 AI 시작 스크립트를 덮어쓰지 않는다. 해당 변경이 포함된 digest를 확인한 후 이 컴포넌트를 활성화한다.

챗봇 README-docker.md와 env.example은 배포용 엔진을 SGLang으로 지정한다. 다만 T4에서 사용할 실제 이미지 버전/digest, 모델 ID/고정 버전·정밀도, 모델 형식, 실행 명령, 메모리 요구량은 추가 확인이 필요하다. 앱의 기본 Ollama 모델 값은 SGLang용 모델 인계로 간주하지 않는다.
확정 뒤 같은 챗봇 Pod에 LLM 컨테이너를 추가하고 다음을 연결한다.

- GPU `nvidia.com/gpu: 1`은 LLM 컨테이너에만 할당한다.
- API에 `LLM_BACKEND=sglang`, `SGLANG_HOST=http://127.0.0.1:30000`을 연결하고, `LLM_MODEL`은 서버의 served-model-name과 맞춘다. 이 주소는 같은 Pod의 SGLang을 30000 포트로 실행할 때 사용한다.
- LLM 모델 형식에 맞는 볼륨과 준비 절차, startup/readiness, CPU/RAM을 추가한다.
- 현재 10Gi 챗봇 PVC는 BGE-M3용이다. LLM까지 충분하다는 의미가 아니다.

## 모델 번들 계약

S3의 변경하지 않는 버전별 prefix에 **전체 런타임 파일과 `SHA256SUMS`**를 올린다. 모델 파일은 Git에 넣지 않는다.
각 번들은 심볼릭 링크를 실제 파일로 풀고, 아래 하위 경로를 유지한다.

```text
상세페이지 prefix/
  SHA256SUMS
  text/       Qwen 전체 snapshot (config, tokenizer, 모든 weight shard 등)
  image/      FLUX 전체 snapshot (model_index.json 및 각 하위 컴포넌트)
  u2net/birefnet-general.onnx

챗봇 prefix/
  SHA256SUMS
  bge-m3/     SentenceTransformer 런타임 전체 파일
```

현재 소스가 지정한 모델:

| 용도 | 모델 | 고정 revision |
| --- | --- | --- |
| 상세페이지 텍스트 | `cyankiwi/Qwen3.8-27B-AWQ-INT4` | `6e134bae811fb5adac50ee042ae5f029ac6779aa` |
| 상세페이지 이미지 | `circulus/FLUX.2-klein-9B-bnb-4bit` | `58c2804f31af12c8888504b96250010c50b55e44` |
| 챗봇 CPU 임베딩 | `BAAI/bge-m3` | `5617a9f61b028005a4858fdac845db406aefb181` |
| 배경 제거 | rembg 2.0.69의 BiRefNet general | 로컬 파일명 `birefnet-general.onnx`; upstream asset `BiRefNet-general-epoch_244.onnx` |

BiRefNet 파일은 rembg 기대 MD5 `7a35a0141cbbc80de11d9c9a28f52697`도 확인해야 한다. 앱은 첫 배경 제거 요청 때 이를 읽으므로 일반 readiness만으로 누락을 발견하지 못한다.

`SHA256SUMS` 형식은 `sha256sum`의 텍스트 출력이다. 경로는 공백 없이 번들 내부 상대 경로로 기록한다. 예:

```text
<파일의 64자리 SHA256>  text/config.json
<파일의 64자리 SHA256>  text/model-00001-of-00005.safetensors
```

실제 목록에는 **모든** tokenizer·config·weight 파일을 넣는다. 최소 파일 검사와 체크섬 검사는 모델 추론 검증을 대신하지 않는다.
`manifest-sha256`에는 `SHA256SUMS` 파일 자체의 SHA256을 넣는다. 로컬 모델 모드에서는 이미지의 revision 인자가 생략되므로 번들 내용과 이 hash가 실제 모델 버전을 고정한다.

준비 스크립트는 manifest hash를 먼저 검사하고 목록의 파일만 다운로드한다. 모든 파일 검증이 끝난 뒤 `.complete`를 만든다. 완료된 번들은 다음 시작 때 재검증하여 재사용하며, 손상되거나 준비가 중단됐으면 다시 받는다.
번들 hash마다 다른 하위 디렉터리를 사용하므로 이전 모델 파일과 앱 SQLite/출력 파일을 삭제하지 않는다. 이전 번들 정리는 배포/롤백 기간이 끝난 뒤 별도 수행한다.

## 공개 이미지 → ECR 수동 복사

`.github/workflows/ai-image-mirror.yml`은 `workflow_dispatch` 전용이다. main 반영 후 Actions의 **Mirror AI runtime image to ECR**에서 실행한다.

| runtime 입력 | 허용하는 공개 이미지 | 복사 대상 저장소 |
| --- | --- | --- |
| `model-fetch` | `public.ecr.aws/aws-cli/aws-cli` | `jangin-ai/model-fetch` |
| `sglang` | `docker.io/lmsysorg/sglang` | `jangin-ai/chatbot-llm` |
| `ollama` | `docker.io/ollama/ollama` | `jangin-ai/chatbot-llm` |

`source_digest`에는 검토한 실제 `sha256:...`만 넣는다. 태그 입력은 거절한다. LLM runtime 선택은 모델 확정 후 진행한다.
Skopeo `--all --preserve-digests`로 원본 manifest/index를 보존하고, ECR에서 같은 digest인지 확인한다. 기존 동일 tag/digest가 있으면 복사를 생략한다. 기존 tag가 다른 digest이거나 접근이 실패하면 중단한다.
Actions Summary에 나온 `ECR주소@sha256:...`를 배포 설정에서 사용한다. 이 workflow는 배포 YAML을 자동 변경하지 않는다.

인프라 담당자에게 필요한 준비:

- 기존 또는 신규 private ECR 저장소 `jangin-ai/model-fetch`, `jangin-ai/chatbot-llm`와 immutable tag 정책.
- **infra 저장소** Actions의 OIDC trust가 연결된 IAM Role ARN. GenAI 저장소용 Role의 trust가 자동으로 적용되는 것은 아니다.
- Role 권한: `ecr:GetAuthorizationToken` 및 대상 저장소의 `DescribeRepositories`, `DescribeImages`, `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage`, `GetDownloadUrlForLayer`.
- infra GitHub Repository Variables: `AWS_ROLE_ARN`, `AWS_REGION` (`ap-northeast-2`). Access Key는 사용하지 않는다.
- 선택한 이미지가 Linux amd64를 지원하고, model-fetch 이미지에 `/bin/sh`, `aws`, `sha256sum`, `awk`가 있는지 확인한다.

## Stage·Prod 활성화 방법

### 공용 모델 버킷

- 기본 프로젝트 이름 기준 `jangin-prod-s3-models` 하나를 Stage·Prod에서 공유한다.
- 버킷·버킷 정책·접근 로깅은 `terraform/environments/prod/s3_models.tf`에서만 관리한다.
- Stage는 `data.aws_s3_bucket.models`로 조회하고 AI IRSA에 공용 버킷의 `s3:GetObject`를 허용한다. Stage 삭제는 공용 버킷을 삭제하지 않는다.
- 인프라팀 확인상 Stage 모델 버킷은 미생성이다. 실제 적용 전 Stage plan에서 기존 모델 버킷 삭제가 없는지 확인한다. Prod 버킷 생성이 Stage 조회보다 먼저여야 한다.
- Prod 삭제는 공용 버킷에도 영향을 준다. Stage 사용 여부와 모델 보존을 확인한 뒤 처리한다.
- 모델 업로드 담당자의 쓰기 권한은 별도이며, Pod에는 다운로드용 읽기 권한만 제공한다.
- 상세페이지는 `page-generation/<번들>/` 아래 `text/`, `image/`, `u2net/`을, 임베딩은 `chatbot/embedding/<번들>/` 아래 `bge-m3/`를 둔다. 각 번들 루트에 `SHA256SUMS`가 필요하다.
- 챗봇 LLM도 같은 버킷의 `chatbot/llm/` 경로를 사용할 수 있지만, LLM 컨테이너·다운로드 연결은 별도 구현이 필요하다.
- 모델 후보는 Hugging Face `main`에서 준비할 수 있다. S3 번들은 환경 간 재현을 위해 덮어쓰지 않는 경로를 사용하고 다운로드 시점의 revision을 기록한다.
- 두 클러스터는 S3 원본만 공유하며 PVC와 모델 복사본은 각각 유지한다. 실제 번들·해시·이미지 digest가 준비되기 전에는 컴포넌트를 활성화하지 않는다.

두 환경에 같은 구조를 제공하되 **각 클러스터의 실제 값**으로 별도 구성한다. 현재는 필수 값과 AI 수정이 미완료라 기본 overlay의 `components`에 추가하지 않았다.
아래 내용은 `k8s/overlays/<stage 또는 prod>/kustomization.yaml`의 기존 항목에 합쳐 넣는 예시이며, `<...>`를 그대로 적용하면 안 된다.

```yaml
components:
  # 기존 components 유지
  - ../../components/ai-model-storage

configMapGenerator:
  - name: ai-sglang-model-source
    namespace: ai
    literals:
      - s3-uri=s3://jangin-prod-s3-models/page-generation/<번들>
      - manifest-sha256=<상세페이지 SHA256SUMS의 64자리 hash>
  - name: ai-chatbot-model-source
    namespace: ai
    literals:
      - s3-uri=s3://jangin-prod-s3-models/chatbot/embedding/<번들>
      - manifest-sha256=<BGE SHA256SUMS의 64자리 hash>

images:
  # 기존 앱 이미지 digest 설정 유지
  - name: ai-model-fetch
    newName: <account>.dkr.ecr.ap-northeast-2.amazonaws.com/jangin-ai/model-fetch
    digest: sha256:<확인한 원본과 동일한 digest>
```

같은 환경의 `ai-worker-sa`에 `eks.amazonaws.com/role-arn` annotation을 patch한다. 해당 Role에는 기존 SSM/CSI 접근 외에 모델 prefix의 `s3:GetObject`가 필요하다. SSE-KMS이면 키 정책과 `kms:Decrypt`도 필요하다. 여기서 버킷/IAM/Endpoint를 생성하지 않는다.

Pod의 S3·regional STS TCP 443 접근을 확인한다. 기본 overlay는 AI **ingress** 정책만 포함한다. 전체 AI egress default deny를 활성화할 때는 S3/STS 목적지 허용을 먼저 추가해야 한다. 표준 NetworkPolicy에 S3 도메인 이름이나 AWS prefix-list ID를 그대로 넣을 수 없다. 확인된 네트워크 방식에 맞춰 별도 구성한다.

모델 initContainer는 Pod와 같은 ServiceAccount, 노드 선택, NetworkPolicy를 사용한다. 앱보다 먼저 실행되고 GPU는 예약하지 않는다.
UID/GID 10001과 `fsGroup: 10001`로 새 PVC에 쓰고 앱에서 읽을 수 있게 한다. 상세페이지는 같은 PVC를 `/var/lib/detail-page-ai`에 마운트하여 모델뿐 아니라 SQLite·결과물·캐시도 유지한다. 챗봇 API는 `/models`를 읽기 전용으로 마운트한다.

## 자원과 배포 전 검증

- L40S: 통합 상세페이지 컨테이너에 GPU 1개. 텍스트/이미지 동시 실행의 VRAM, RAM, 시작 시간은 실측 전이다. `/dev/shm` 요구량도 실제 SGLang 실행으로 확인해야 한다.
- T4: CPU용 챗봇 API + 별도 LLM + vector DB의 합계로 산정한다. 현재 API의 GPU 할당 제거만 완료됐고 LLM 컨테이너는 아직 없다.
- 100Gi/10Gi는 시작 용량이며, 이전 번들·앱 출력·캐시 여유를 포함해 검증한다. EBS는 AZ에 묶이므로 대체 GPU 노드가 PVC와 같은 AZ에서 뜰 수 있어야 한다.
- StorageClass는 `WaitForFirstConsumer`, `Retain`, 확장 허용이다. PVC 삭제 후 남는 EBS 정리 절차가 필요하다.
- startupProbe 시간 600초는 챗봇 예열을 위한 초기값이다. readiness는 준비 여부이고 실제 답변 품질·GPU 사용량 검증은 별도다.

로컬 검증:

```bash
ruby scripts/validate-ai-runtime.rb
ruby scripts/validate-networking.rb
bash scripts/validate-k8s.sh
```

`validate-ai-runtime.rb`은 실제 S3/이미지를 사용하지 않는다. 임시 Stage/Prod overlay를 렌더링하고, 작은 파일과 모의 AWS CLI로 최초 준비·캐시·손상 복구·다운로드 실패·잘못된 manifest 거절을 검사한다.

실제 Stage에서는 ECR pull, IRSA/SSM 마운트, S3 모델 준비, PVC 재사용, 두 상세페이지 모델 로딩, 배경 제거 요청, callback 저장, 챗봇 DB/LLM 연결과 답변 생성, GPU/CPU/RAM 사용량을 확인한다. 성공한 동일 이미지·모델 버전을 Prod로 승격한다.

근거: [Skopeo copy](https://github.com/containers/skopeo/blob/main/docs/skopeo-copy.1.md), [Kubernetes init containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/), [rembg BiRefNet](https://github.com/danielgatis/rembg/blob/v2.0.69/rembg/sessions/birefnet_general.py), [고정 FLUX 파일 목록](https://huggingface.co/api/models/circulus/FLUX.2-klein-9B-bnb-4bit/revision/58c2804f31af12c8888504b96250010c50b55e44).
