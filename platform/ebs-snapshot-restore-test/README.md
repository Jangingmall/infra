# Stage EBS 스냅샷 복원 시험 (실행 승인 전 준비본)

이 디렉터리와 `scripts/ebs_snapshot_restore_test.py`만 이번 시험 전용이다. 기존 S3/WAL CNPG 복원 코드는 사용하거나 변경하지 않는다. [CNPG 1.28 부트스트랩](https://cloudnative-pg.io/docs/1.28/bootstrap/)은 기본적으로 새 PGDATA를 만들고, [CNPG의 볼륨 스냅샷 복원](https://cloudnative-pg.io/docs/1.28/recovery/)은 CNPG 호환 `VolumeSnapshot` 입력을 사용한다. 이번 입력은 일반 AWS EBS 스냅샷이므로 단독 PostgreSQL Pod를 선택했다. 서비스/백업 사이드카, Service, Ingress, IAM 토큰을 만들지 않는다. Pod의 TCP 리슨은 끄고 유닉스 소켓으로만 검사하며 모든 Ingress/Egress를 거부한다.

## 사전 점검

별도 실행 승인 후 담당자가 `config.example.json`을 작업용 JSON으로 복사해 빈 값과 실제 원본 태그를 채운다. 작업 파일·증거·상태 기록은 Git에 추가하지 않는다. `approvedStageClusterArn`은 담당자가 승인한 Stage EKS ARN을 입력하고, 실제 EKS의 Stage 환경 태그 키/값도 맞춘다. 두 검사가 모두 맞아야 진행한다. 태그가 없거나 미확정이면 생성하지 않는다. `nodeName`은 System-medium 후보(당시 IP `10.1.28.25`)의 실제 DNS 이름을 **실행 직전** 확인해 입력한다. System-large는 이번 시험에서 제외한다. `image`, `pgMajor`, `dataDir`, `mountPath`, `fsType`, 실행 UID/GID는 이전 시험 추측값이 아닌 원본 EBS/PV/Pod의 실제 값과 맞춘다. 원본이 별도 WAL PVC·tablespace를 사용한다면 이 절차를 중단한다.

1. AWS 계정·Stage EKS, 원본 EBS의 소유 태그, 20GiB/암호화/available/Attachments=[], 서비스 DB/PVC의 EBS와 다른지 확인한다. 스크립트가 이 항목과 후보 노드의 AZ, taint, Ready, CPU/메모리 requests(일반·init container와 overhead 포함), Pod 수, EBS CSI 연결 슬롯을 다시 검사한다. CSI 한도나 서비스 PVC 소유를 읽을 수 없으면 중단한다. 노드 IP는 식별자가 아니다.
2. **원본 시험 DB의 스냅샷 시점 기준값**을 정한다. 쓰기를 막은 뒤 원본 시험 DB에서 `pg_catalog.pg_class`의 일반·파티션 테이블(`relkind IN ('r','p')`, 시스템/TOAST/임시 스키마 제외) 전체 목록을 조회한다. 각 테이블의 `count(*)`만 수집해 구성의 `expectedCounts`와 증거의 `sourceTables`·`sourceCounts`에 기록한다. 세 집합이 완전히 같지 않으면 코드가 중단한다. 목록 일부만 기록하거나 현재 서비스 DB를 기준으로 삼지 않는다. 회원 데이터 행·시크릿은 출력하지 않는다. 이어 같은 EBS의 PostgreSQL을 정상 종료하고 아직 마운트된 원본 `PGDATA`에 같은 major 버전의 `pg_controldata`를 실행해 `Database cluster state: shut down`을 확인한다. 그 뒤 언마운트·분리한다. 종료를 증명할 수 없으면 일관된 스냅샷이라 판단하지 말고 중단한다.

   원본과 복원 DB의 테이블 목록 조회식은 동일하게 사용한다: `SELECT n.nspname || '.' || c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%' ORDER BY n.nspname, c.relname;` 이 목록 전부에 `count(*)`를 실행한다.
3. 실행 직전 `--evidence` JSON을 **작업용 경로**에 작성한다. 필수 필드: `volumeId`, `database`, `pgMajor`, `dataDir`, `image`, `fsType`, `writesFenced: true`, `countsAt`, `stoppedAt`, `pgControlObservedAt`(UTC 시각), `pgControlState: "shut down"`, `sourceTables`(전체 `schema.table` 배열), `sourceCounts`(같은 테이블의 행 수 객체). 스냅샷 명령은 목록·기준값의 SHA-256을 상태 파일에 고정한다. 이후 구성 또는 증거를 바꾸면 볼륨 생성·렌더·검증이 중단된다. 이는 작업자 증거 기록이며 스크립트가 원본 파일을 대신 검사한다는 뜻이 아니다. 스냅샷 실행 시 종료 증거가 한 시간 넘게 오래되면 재확인해야 한다.

## 실행·검증 (별도 승인 후)

Python 3.10+, `boto3`, `kubectl`과 승인된 AWS/Kubernetes 읽기 권한이 필요하다. 아래 `cfg`, `ev`, `state`, `manifest`는 실제 안전한 절대 경로로 바꾼다. 이 단계는 이번 준비 세션에서 **실행하지 않았다**.

```powershell
python scripts/ebs_snapshot_restore_test.py --config cfg --evidence ev preflight
python scripts/ebs_snapshot_restore_test.py --config cfg --evidence ev --state state snapshot
python scripts/ebs_snapshot_restore_test.py --config cfg --evidence ev --state state create-volume
python scripts/ebs_snapshot_restore_test.py --config cfg --evidence ev --state state render --output manifest
kubectl apply -f manifest
python scripts/ebs_snapshot_restore_test.py --config cfg --evidence ev --state state observe
```

`snapshot`은 시험 ID 태그의 기존 스냅샷을 확인하고 Completed까지 기다린다. `create-volume`은 같은 스냅샷의 시험 EBS를 확인하고 같은 AZ에 암호화된 gp3 20GiB를 만든 뒤 available까지 기다린다. 둘 다 중복 태그·ID 불일치 때 중단한다. **동시에 두 실행자를 돌리지 않는다.** EBS 기본 gp3 성능을 사용하며 FSR, 유료 초기화율, Archive 옵션을 요청하지 않는다. [AWS 설명](https://docs.aws.amazon.com/ebs/latest/userguide/initalize-volume.html)에 따라 available은 전체 블록 초기화 완료가 아니다.

`render` 결과는 Retain PV/PVC, 네트워크 격리 정책, PostgreSQL Pod 각 1개다. 원본 EBS를 포맷하거나 마운트하지 않는다. Pod에는 한 컨테이너만 있고 initContainer/sidecar가 없어 계산한 requests가 Pod 전체 요청량이다. 기동 전 PG_VERSION과 `pg_controldata` 정상 종료를 다시 검사하고, `archive_mode=off`, TCP 수신 비활성, IAM 토큰 미마운트로 기존 백업 경로에 쓰지 않게 한다. Pod가 Ready되지 않으면 데이터를 변경하는 수동 수리 대신 중단·원인 검토가 우선이다.

`observe`는 **새 EBS CreateVolume 요청 시각**을 공통 시작점으로 available, Pod Ready, SQL 성공, 복원 DB의 전체 테이블 목록·테이블별 count 비교 완료의 UTC 시각만 상태 파일에 기록한다. 복원 테이블 목록이 원본 증거와 다르면 행 수를 검사하지 않고 중단한다. 스냅샷 생성 시작·완료 시각은 별도다. 실제 테이블 내용이나 자격증명은 출력하지 않는다. 행 수 일치는 전체 데이터 동일성 증명이 아니다. 이 결과는 격리 복원 시간이며 서비스 RTO가 아니다. SQL 접속이 소켓 peer 인증과 맞지 않으면 임의로 비밀번호를 출력·주입하지 말고 담당자와 검토한다.

## 정리 (명시적 정리 승인 후)

정리 전 `state`의 `testId`, snapshot/volume ID와 AWS의 `DrillId`/`Purpose`/원본 volume 연결, Kubernetes 네 리소스의 `drill-id`를 다시 대조한다. 원본 `sourceVolumeId`, `jangingmall-postgres` 및 그 PVC/PV는 삭제 목록에 절대 넣지 않는다. 승인 후 시험 Pod를 멈추고 NetworkPolicy/PVC/PV를 삭제한다. PV는 `Retain`이므로 PVC 삭제만으로 EBS가 사라졌다고 판단하지 않는다. EBS `available`/Attachments=[]를 확인한 뒤 시험용 볼륨과 스냅샷만 ID로 정리하고 AWS `DescribeVolumes`/`DescribeSnapshots`에서 최종 부재와 잔존 과금을 확인한다. 정리 자동 명령은 제공하지 않는다.

## 권한·비용·미검증

- 박다정 전달: 실행 주체의 STS `GetCallerIdentity`, EKS `DescribeCluster`, EC2 `DescribeVolumes`, `DescribeSnapshots`, `DescribeInstances`, `DescribeFastSnapshotRestores`, `CreateSnapshot`, `CreateVolume`, `CreateTags`(생성 시 태그), 해당 시험 ID로 한정한 `DeleteVolume`/`DeleteSnapshot`(정리 시 별도 승인)을 검토. [EBS 암호화 권한](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption-requirements.html)에 따라 해당 KMS 키의 `DescribeKey`, `GenerateDataKeyWithoutPlaintext`, `Decrypt`, `ReEncrypt`, `CreateGrant` 필요성을 실행 역할·EBS CSI 노드 역할·키 정책에서 확인한다. `CreateGrant`는 `kms:GrantIsForAWSResource` 조건을 적용한다. `CreateTags`는 `ec2:CreateAction`을 `CreateSnapshot`/`CreateVolume`에 한정한다. 생성·삭제는 가능한 리소스/태그 조건으로 제한하고 기존 서비스 볼륨에 대한 삭제 권한을 주지 않는다. K8s 읽기와 시험 PV/PVC/Pod/NetworkPolicy 쓰기 권한은 박명수 검토.
- 예상 생성: 암호화 EBS 스냅샷 1, 새 gp3 20GiB 1, PV/PVC/Pod/NetworkPolicy 각 1. EBS 용량·스냅샷 저장량과 API/KMS 부대 요청에 비용이 생길 수 있다. 기존 노드 사용, 신규 EC2/NAT/VPC Endpoint 없음. 미정리 스냅샷/볼륨은 계속 과금될 수 있다.
- 실환경 미검증: 설치된 CNPG 버전, 원본 현재 태그·종료 상태·서비스 PVC 분리, 후보 노드 용량/연결 슬롯, 이미지 UID/GID/PGDATA/파일시스템·소켓 인증, KMS/IAM 권한, 클러스터 정책과 CSI 마운트, SQL/행 수/복원 시간. 사용자 실행 승인 이후에만 확인한다.
