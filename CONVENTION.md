# 커밋 & PR 컨벤션

## 타입

| 카테고리 | 의미 | 예시 |
|---|---|---|
| `Feat` | 새 기능/리소스 추가 | `Feat: EKS 노드그룹 모듈 추가` |
| `Fix` | 버그, 잘못된 설정 수정 | `Fix: ALB 헬스체크 경로 오류 수정` |
| `Chore` | 설정, 패키지, 잡일성 변경 | `Chore: gitignore에 tfstate 추가` |
| `Docs` | 문서 수정 | `Docs: README 아키텍처 다이어그램 업데이트` |
| `Refactor` | 기능 변화 없는 구조 개선 | `Refactor: terraform 모듈 디렉토리 재구성` |


## 브랜치 네이밍

```
카테고리/작업내용
```
**예시**
```
feat/eks-nodegroup
fix/alb-healthcheck
chore/gitignore-update
```


## 커밋 메시지 형식

```
[카테고리]: 설명
```

- 설명은 한글/영어 자유, 간결하게

**예시**
```
[Feat]: add EKS node group module
[Fix]: correct sync policy for prod app
[Chore]: update tfvars.example
[Docs]: update README
```


## PR 제목

```
[카테고리] 설명
```

**예시**

```
[Feat] KEDA ScaledObject 3-trigger 로직 추가
[Fix] YACE 메트릭 수집 안되는 이슈 해결
```


## 원칙

- 초기 세팅(README, gitignore 등)만 main에 직접 커밋, 그 외에는 Branch → PR → Merge 필수
- 하나의 Commit/PR은 하나의 작업 단위로 유지 (여러 타입 섞지 않기)
- 민감정보(`.tfvars`, AWS 키 등)는 커밋 전 반드시 확인