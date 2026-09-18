# 업무용 Redis

Backend의 인증 토큰·이메일 인증·요청 횟수 데이터를 위한 Redis다. Argo CD 내부 Redis와 별개다.
Stage와 Prod의 각 클러스터에 동일한 구조로 배치한다. 실제 배포·SSM 연결 검증은 미실시다.

## 구성

- StatefulSet 1개, `workload-type=app`; `redis.app.svc.cluster.local:6379`.
- Redis 7.4.11 bookworm, UID/GID 999, 읽기 전용 루트 파일시스템.
- 암호화된 gp3 PVC 4Gi. PVC 삭제/축소 및 StorageClass reclaimPolicy는 Retain.
- requests CPU 100m/192Mi, limits CPU 1/512Mi. `maxmemory 128mb`, `noeviction`.
- AOF everysec 및 RDB. 메모리 제한은 데이터만의 한도이며 AOF rewrite·연결 버퍼·프로세스 메모리는 별도다.
- Backend namespace와 Pod label을 모두 만족하는 출발지만 6379 허용. Redis의 신규 egress는 차단한다.
- 설정 변경은 ConfigMap 해시가 변경되어 StatefulSet에 반영된다.

단일 인스턴스이므로 재시작·노드 장애·EBS 재연결 중 중단이 있다. AOF everysec는 장애 시 최근 약 1초의 쓰기가 유실될 수 있다. Retain과 AOF는 외부 백업·HA를 대체하지 않는다. 메모리가 차면 인증 데이터를 임의 삭제하는 대신 쓰기가 실패하므로 실제 메모리와 로그인 오류를 함께 확인한다. TLS는 구성하지 않았으며 클러스터 내부 인증과 NetworkPolicy를 사용한다.

## Secret 계약

| 환경 | SSM SecureString |
| --- | --- |
| Stage | `/staging/backend/redis-password` |
| Prod | `/prod/backend/redis-password` |

비밀번호 형식은 줄바꿈 없는 64자리 16진수다. Infra 담당이 환경별로 서로 다른 값을 생성·등록한다(`openssl rand -hex 32`). 실값을 Git이나 문서에 붙이지 않는다.

동일 파라미터를 두 Pod가 파일로 읽는다.

1. Redis: `redis-sa` → CSI `redis-config` → `/mnt/redis-secrets/password` → 시작 시 SHA-256 ACL 해시 생성.
2. Backend: `backend-sa` → 기존 CSI configtree → 파일명 `spring.data.redis.password`.
3. 주소는 Rollout의 `REDIS_HOST=redis.app.svc.cluster.local`, `REDIS_PORT=6379`로 지정한다. 이전 `redis-host` SSM 항목은 더 이상 요구하지 않는다.

실제 IRSA ARN을 환경 overlay의 두 ServiceAccount annotation에 반영해야 한다. Redis 역할의 trust subject는 `system:serviceaccount:app:redis-sa`, 권한은 해당 파라미터 읽기와 필요한 KMS decrypt로 제한한다. Backend 역할에도 같은 파라미터 읽기 권한이 필요하다. `secretObjects`로 Kubernetes Secret을 복제하지 않는다.

비밀번호 변경은 파일 회전만으로 Redis ACL·Spring 설정에 즉시 반영되지 않는다. 점검 시간에 SSM 변경, CSI 파일 갱신 확인, Redis 재시작, Backend 재시작 및 인증 시험을 수행한다. 단일 Redis이므로 이 과정은 무중단을 보장하지 않는다. 기존 Redis의 데이터 이전은 자동 수행하지 않는다.

## 검증

`bash scripts/verify-redis.sh`는 별도 Docker 볼륨/컨테이너와 가짜 비밀번호로 인증 실패, Lua, GETDEL, AOF 재시작 복원, 관리자 명령 차단, 빈/누락 Secret 실패를 확인한다. 실제 업무 데이터에는 접근하지 않는다.

EKS에서는 CSI 마운트·IRSA, App 배치, EBS 재연결, Backend 로그인/이메일 인증 및 비허용 Pod의 새 TCP 연결 차단을 확인한다. Backend 전체 egress 번들은 기존과 같이 별도 활성화 대상이며 그 번들에도 Redis 6379를 추가했다.
