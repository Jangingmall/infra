# CloudNativePG Operator

장인몰 PostgreSQL Cluster를 Kubernetes에서 관리하기 위한
CloudNativePG Operator 설치 설정을 관리한다.

## 역할

CloudNativePG Operator는 다음 기능을 담당한다.

- PostgreSQL Cluster 생성 및 관리
- Primary / Replica 관리
- 장애 감지
- Replica Promotion / Failover
- PostgreSQL Pod lifecycle 관리
- PVC 기반 Storage 연계

실제 장인몰 PostgreSQL Cluster 정의는
`k8s/base/database/`에서 관리한다.

## 설치 Namespace

`cnpg-system`

Operator와 실제 Database Workload를 분리한다.

```
cnpg-system
└─ CloudNativePG Operator

database
├─ PostgreSQL Primary
├─ PostgreSQL Replica
└─ PostgreSQL Replica
```

## Bootstrap Credential

Application DB Credential의 Source of Truth는 AWS Parameter Store로 관리한다.

CloudNativePG 초기 Bootstrap에서는 아래 Kubernetes Secret을 참조한다.

- Namespace: `database`
- Secret: `jangingmall-postgres-app`
- Type: `kubernetes.io/basic-auth`
- Username: `jangingmall`

`k8s/base/database/cluster.yaml`에는 Secret 이름만 선언하며,
실제 username/password 값을 Git에 저장하지 않는다.

실제 EKS 배포 시에는 CloudNativePG Cluster가 생성되기 전에
Parameter Store의 Credential을 기반으로 해당 Runtime Secret을 먼저 준비해야 한다.

Backend는 이 CNPG Bootstrap Secret을 직접 사용하지 않고,
Secrets Store CSI Driver → Volume Mount → Spring `configtree` 경로를 사용한다.
