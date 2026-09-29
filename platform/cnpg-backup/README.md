# CNPG S3 백업 및 복구

업무 DB `database/jangingmall-postgres`의 기본 백업과 WAL을 S3에 보관하는 구성이다. AI 벡터DB와 Redis의 외부 백업은 이 구성의 대상이 아니다. 코드·로컬 렌더링과 실제 S3 백업/복구 완료를 구분한다.

## 구성 명세

| 항목 | 설정 |
| --- | --- |
| cert-manager | chart v1.20.4, CRD 유지, System 배치 |
| Barman Cloud plugin | chart 0.8.0, controller/sidecar v0.15.0 |
| Plugin Controller | cnpg-system, System 배치 |
| DB sidecar | 기존 DB Pod마다 추가; DB 노드 유지 |
| 저장 경로 | Stage `s3://<bucket>/cnpg/staging`, Prod `s3://<bucket>/cnpg/prod` |
| 인증 | 기존 `database/cnpg-backup-sa`의 IRSA, 정적 AWS 키 없음 |
| 보존 | ObjectStore recovery window 30d |
| 정기 백업 | 기본(Prod) UTC 18:00 / KST 03:00, Stage UTC 01:00 / KST 10:00 매일; 6필드 cron |
| 대상 | prefer-standby, replica에서 우선 수행 |
| WAL | gzip, maxParallel 2, archive_timeout 5min |
| 기본 백업 | gzip, jobs 1 |

30d는 복구 가능 기간이며 모든 객체가 정확히 30일째 삭제된다는 뜻이 아니다. 기본 백업과 필요한 WAL을 플러그인이 함께 관리한다. S3 Lifecycle은 이를 앞서 삭제하면 안 된다. 기존 계획의 recovery window 30일 + safety 7일보다 짧게 설정하지 않고, 실제 체인과 별도 승인된 객체 정리 정책을 확인한다. `archive_timeout`은 RPO 보장값이 아니며 업로드 장애·지연이 더해질 수 있다.

## 안전한 초기 상태와 소유권

`values.yaml`은 `enabled=false`, `suspend=true`다. Stage에서는 환경 values로 ObjectStore 생성을 선택하되 정기 백업은 중지한다. Stage overlay의 WAL 컴포넌트 변경은 IAM 권한 적용과 ObjectStore 수동 Sync를 확인한 뒤 merge해야 한다.

- 기존 workloads Application만 CNPG Cluster를 소유한다.
- cnpg-backup Application은 ObjectStore, ScheduledBackup, Plugin ingress 정책을 소유한다.
- cert-manager 및 barman-cloud Application은 각각 의존 플랫폼을 설치한다.
- 세 Application은 Stage/Prod 모두 수동 Sync다. main 참조이므로 변경 merge 전에는 배포되지 않는다.
- 기존 cert-manager가 있으면 기존 설치를 재사용한다. 중복 설치하거나 CRD 소유권을 임의로 가져오지 않는다.

## 활성화 순서

### Stage 상태 (2026-09-28)

- 버킷: `jangin-staging-s3-backup`, 경로: `cnpg/staging`.
- IRSA: `arn:aws:iam::750240012008:role/jangin-staging-irsa-cnpg`; trust subject는 `system:serviceaccount:database:cnpg-backup-sa`와 일치한다.
- 버킷 KMS: `arn:aws:kms:ap-northeast-2:750240012008:key/48fa2655-2c4e-43c4-828c-ca511da66c26`.
- 해당 prefix의 S3 GetObject/PutObject/DeleteObject와 S3 경유 KMS GenerateDataKey/Decrypt는 IAM simulator에서 allowed다. KMS 조건은 `kms:ViaService=s3.ap-northeast-2.amazonaws.com`이다.
- `stage-barman-cloud`와 `stage-cnpg-backup`은 수동 Sync되어 있다. ObjectStore와 백업 sidecar가 실행 중이며 CNPG 3/3 Ready, ContinuousArchiving=True다.
- 첫 수동 백업 `cnpg-manual-f25b6`는 completed이고 S3에 base backup과 WAL이 생성됐다. 별도 복원 시험은 아직 하지 않았다. 정기 백업은 `suspend: true`다.
- sidecar가 ObjectStore를 읽을 Kubernetes RBAC가 누락되어 Stage에 수동 적용했다. 이 브랜치의 `templates/objectstore-rbac.yaml`을 merge하고 `stage-cnpg-backup`을 다시 Sync하여 GitOps로 관리해야 한다.

남은 순서: RBAC 변경 merge·수동 Sync → 별도 복원 검증 → 정기 백업 활성화.

1. Infra 담당에게 환경별 버킷/리전/KMS, S3·regional STS 통신 경로, IRSA ARN을 받는다. trust subject는 `system:serviceaccount:database:cnpg-backup-sa`다. 버킷 목록 조회는 prefix 조건, 객체 권한은 해당 환경 prefix의 Get/Put/Delete 등 백업 도구에 필요한 범위로 제한한다. SSE-KMS 사용 시 `kms:ViaService=s3.<region>.amazonaws.com` 조건으로 GenerateDataKey/Decrypt 권한을 확인한다.
2. cert-manager를 Sync하고 webhook/CRD 준비를 확인한다. plugin을 Sync하고 Deployment·인증서·`barman-cloud:9090`을 확인한다. 이 TLS 인증서 Secret은 컨트롤러 인증서이며 앱 비밀번호 복제를 의미하지 않는다.
3. `platform/cnpg-backup/{stage,prod}.yaml`에 실제 `bucket`, `enabled: true`를 넣는다. `suspend: true`는 유지한다. backup Application을 Sync하여 ObjectStore와 `cnpg-backup-sa`의 해당 ObjectStore 조회 RBAC를 생성한다.
4. 환경 overlay에서 기존 `cnpg-backup-sa`에 실제 IRSA annotation을 추가한다. Cluster의 기존 `serviceAccountName`과 `serviceAccountTemplate`은 함께 사용할 수 없으므로 Template을 추가하지 않는다.
5. Stage overlay에 준비된 `../../components/cnpg-backup` 변경을 ObjectStore 확인 후 merge한다. workloads Application이 자동 Sync하면서 DB Pod에 sidecar가 추가되는 rolling update를 확인한다.
6. 아래 수동 백업을 실행하고 완료 상태, S3 기본 백업/WAL, 오류 로그를 확인한다.
7. 별도 복원 시험이 성공한 후 환경 values의 `suspend: false`를 반영하고 backup Application을 수동 Sync한다. 첫 정기 백업의 성공도 확인한다.

```sh
kubectl -n cnpg-system get deploy plugin-barman-cloud
kubectl -n database get objectstores.barmancloud.cnpg.io
kubectl -n database get cluster jangingmall-postgres
kubectl create -f platform/cnpg-backup/backup-on-demand.yaml
kubectl -n database get backups.postgresql.cnpg.io
kubectl -n database get scheduledbackups.postgresql.cnpg.io
```

백업 실패 시 성공으로 처리하거나 운영 데이터를 삭제하지 않는다. IAM/KMS, S3·STS 경로, ObjectStore, plugin/sidecar 로그, pg_wal 디스크 사용량부터 확인한다. 아카이브 실패가 지속되면 WAL이 쌓여 DB 디스크가 고갈될 수 있다.

## 백업 감시 경보

경보 규칙은 이 차트가 아니라 공통 규칙 파일 `platform/observability/alerts/rules/prometheus-rules.yaml`의 `janging.backup` 그룹에 둔다. Prometheus는 `monitoring` namespace의 `release=metrics` 규칙만 읽으므로 이 차트(`database` namespace)에서 PrometheusRule을 만들면 로드되지 않는다.

| 경보 | 조건 | 심각도 |
| --- | --- | --- |
| CNPGBackupStale | 마지막 백업 성공 후 26시간 초과, 30분 | Critical |
| CNPGBackupFailed | 마지막 실패 시각 > 마지막 성공 시각, 5분 | Critical |
| CNPGBackupMetricsMissing | CNPG는 수집되는데 백업 시각 메트릭 없음, 1시간 | Warning |
| CNPGWALArchiveFailing | Primary의 WAL 마지막 실패 > 마지막 성공, 10분 | Critical |
| CNPGWALArchiveBacklog | ready WAL 5개 초과, 15분 | Warning |

- 디스크 위험은 기존 `PVCUsageHigh`(database 80/90%)가 담당한다.
- 백업 시각 메트릭 이름 `barman_cloud_cloudnative_pg_io_last_{available,failed}_backup_timestamp`는 plugin 문서 기준이며 **Stage 실환경 미확인**이다. 아래 명령으로 이름을 확인하고, 다르면 규칙과 테스트를 함께 고친다.

```sh
kubectl -n database port-forward pod/<primary-pod> 9187:9187
curl -s http://localhost:9187/metrics | grep -E "backup_timestamp|pg_stat_archiver_last|wal_archive_status"
```

- Stage 노드를 장시간 중지한 뒤 첫 예약 전까지 `CNPGBackupStale`이 발생할 수 있다. 백업이 실제로 없다는 의도된 신호다.
- 과거 누적 WAL 실패 횟수는 판단에 쓰지 않는다. 실패 이후 성공이 있으면 발생하지 않는다.

## NetworkPolicy

CNPG Operator → Barman plugin TCP 9090 ingress만 선택적으로 허용한다. DB의 S3/STS egress는 기존 전체 egress 번들의 실제 목적지 계약이 필요하다. 이 변경은 임의의 인터넷 전체 허용을 추가하지 않는다. CSI의 SSM 통신과 DB sidecar의 S3/STS 통신을 구분한다.

## 복원 수용 절차

1. Stage에서 테스트 데이터를 기록하고 기본 백업 완료 시각과 이후 WAL 업로드를 기록한다.
2. 기존 Cluster/PVC를 덮어쓰지 않고 별도 이름·새 PVC의 복원 Cluster를 만든다. 추가 DB 자원과 EBS 용량을 먼저 확보한다.
3. 별도 읽기 전용 IRSA ServiceAccount와 복원용 ObjectStore를 사용한다. 원본과 동일한 destinationPath를 가리키되 복원용 ObjectStore에는 retentionPolicy를 넣지 않는다.
4. 복원 Cluster의 `externalClusters`에서 Barman plugin을 지정하고 parameters의 `barmanObjectName`은 복원용 ObjectStore, `serverName`은 원본 `jangingmall-postgres`로 지정한다. `bootstrap.recovery.source`는 이 externalCluster 이름을 참조한다. PITR이면 승인된 시각을 recoveryTarget에 명시한다.
5. 백업에 들어 있는 DB 계정으로 인증하고 기준 데이터/행 수/업무 쿼리 및 원하는 시점 이후 데이터 제외를 확인한다. 기존 bootstrap Secret 변경만으로 복원된 계정 비밀번호가 바뀌지 않는다.
6. 장애 기준 시각, 마지막 복원 데이터 시각, 복원 시작/종료를 기록해 RPO/RTO를 실측한다. Backend 전환·쓰기 재개는 별도 승인 대상으로 남긴다.

복원 리소스는 환경과 복구 목표에 따라 작성해야 하므로 운영 Cluster를 자동 변경하는 복원 Job을 배포하지 않는다. 실제 S3 쓰기·PITR·복구 시간은 아직 검증하지 않았다.

## 추가 자원 및 로컬 검사

- System 상시 requests: cert-manager 3개 75m/192Mi + plugin 100m/128Mi = **175m/320Mi**. 설치 Job은 별도 50m/32Mi.
- DB 각 Pod sidecar requests 100m/128Mi, limits CPU 1/512Mi. 3개 합계 requests **300m/384Mi**.
- 백업 시 압축 CPU, WAL 보관 디스크, 임시 메모리를 실측해야 한다. t3.small DB 노드가 충분하다고 단정하지 않는다.
- `ruby scripts/validate-data-services.rb`는 두 환경의 Secret 계약·배치·백업 비활성 기본값·환경 경로 격리·WAL component·수동 Sync를 확인한다.
- `bash scripts/validate-k8s.sh`는 플랫폼 chart와 Kustomize 전체 구성을 함께 검증한다.

## 근거

- https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/
- https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/
- https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/
