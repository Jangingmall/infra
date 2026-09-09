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
