# Argo CD 설치 설정

공식 argo-cd chart **10.9.1**, Argo CD **v3.5.3**으로 고정한다.
2026-09-16 공식 Helm 저장소에서 chart와 appVersion을 조회했고 로컬 lint/render를 검증한다.
차트 요구 Kubernetes 버전은 >=1.25.0이다. 실제 EKS 설치 직전 호환성·보안 패치를 다시 확인한다.

각 환경 EKS에 동일 values로 별도 설치하고 해당 환경 Application만 등록한다.
중앙에서 두 환경을 관리하는 방식도 설계상 가능하지만, 이번 구현은 환경 순차 가동과 권한 분리를 위해 환경별 설치를 선택했다.
두 환경 동시 가동 비용까지 승인된다는 의미는 아니다.

## 구성

- System 노드에 controller, server, repo-server, Redis, ApplicationSet controller를 배치한다.
- 단일 replica 구성으로 Argo CD 자체 HA를 보장하지 않는다.
- 상시 requests 합계는 CPU 550m / 메모리 1152Mi다. Redis 초기화 Job은 50m/64Mi가 추가된다.
- 실측 전 초기값이며 기존 System 노드 사이징표에 반영하고 관측성 자원과 합산해야 한다.
- 내부 Redis는 Argo CD 캐시/조정을 위한 의존성이다. 보류한 Backend 앱용 Redis를 제공하지 않는다.
- server는 TLS를 유지하며 ClusterIP만 사용한다. Ingress·익명 접근·Pod exec UI는 비활성이다.
- Dex와 알림은 이번 기본 구성에서 끈다. SSO는 IdP 계약 인계 후 별도 연결한다.
- 기본 로그인 사용자는 readonly 권한이다. 초기 admin은 부트스트랩에만 사용하며 SSO/운영 계정 인계 후 정책을 조정한다.
- 자동 생성 admin 비밀번호나 Git repository 자격증명은 Git에 넣지 않는다.

## 설치 (실행 전 조건 확인)

아래는 운영자용 절차이며 이 작업에서 클러스터에 실행하지 않았다.
`--kube-context`에는 반드시 확인한 해당 환경 context를 넣는다.

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version 10.9.1 \
  --namespace argocd --create-namespace \
  --values platform/argocd/values.yaml \
  --kube-context '<해당 환경 context>' --wait --timeout 10m
```

접근은 인증된 Kubernetes 사용자로 `kubectl --context '<해당 환경 context>' -n argocd port-forward svc/argocd-server 8443:443`를 실행하고 localhost:8443을 사용한다.
신뢰할 인증서를 설치하거나 클라이언트에 CA를 제공한다. 무조건 TLS 검증을 끄는 것을 기본 절차로 두지 않는다.
비밀번호 조회 결과를 CI 로그·문서·채팅에 남기지 않는다.

Private Git 저장소라면 Argo CD에 read-only repository credential을 안전한 경로로 등록한다.
이미지 승격 PR 생성용 GitHub App write 권한을 Argo CD의 저장소 읽기 권한과 혼용하지 않는다.
Argo CD 자체는 Helm으로 부트스트랩하고 Application으로 자기 자신을 관리하지 않는다.

Application 등록·운영은 `argocd/README.md`를 따른다.
