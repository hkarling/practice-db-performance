# practice-db-performance

쿼리 성능 학습 프로젝트. Olist 이커머스 스키마(고객/판매자/상품/주문 등)를 기반으로
대용량 데이터(주문 500만, 주문상품 1500만 수준)에서 실행 계획을 읽고, 인덱스를 설계하고,
JPA/QueryDSL 레벨의 N+1·페이지네이션·집계 쿼리를 최적화하는 과정을 단계별로 기록한다.

## 기술 스택

- Java 21
- Spring Boot 4.1.0
- Spring Data JPA + Hibernate 7.4.1 + QueryDSL
- PostgreSQL (docker compose로 로컬 기동)
- Gradle

## 아키텍처

hexagonal 기본 컨셉을 유지하되 불필요한 depth는 만들지 않는다.

```
io.hkarling.practice
├── Application.java
├── domain    # 엔티티, 핵심 비즈니스 규칙
├── app       # 유스케이스, 서비스
└── infra     # Repository(JPA/QueryDSL), 외부 연동
```

- `common`, port/adapter 인터페이스 분리는 실제로 필요해질 때 도입한다.
- 자세한 설계 이유는 [docs/LOG000-project-setup.md](docs/LOG000-project-setup.md) 참고.

## DB 환경 전략

- **로컬 PostgreSQL (docker compose, 고정)**: 쿼리 성능 실험 전용. `compose.yaml`로 기동하며,
  named volume에 데이터가 영속화되고 앱 종료 시에도 컨테이너는 유지된다(`lifecycle-management: start-only`).
  최초 1회 대용량 시드를 적재해두고 계속 재사용한다.
- **Testcontainers**: 기능/결과 검증 전용 테스트에서만 사용. 테스트별 최소 픽스처.
- 스키마는 `db/schema.sql`(SQL DDL)로 직접 관리하고, Hibernate는 `ddl-auto: validate`로
  엔티티-스키마 매핑만 검증한다(엔티티가 스키마를 소유하지 않음).

## 로컬 실행법

```bash
# 1. 로컬 Postgres 기동 (Docker Desktop 필요)
./gradlew bootRun   # spring-boot-docker-compose가 compose.yaml을 자동 기동

# 2. 스키마 적용 (최초 1회, 로컬에 psql이 없다면 컨테이너 내부 psql 이용)
docker exec -i practice-db-performance-postgres-1 psql -U practice -d practice_db_performance < db/schema.sql
```

## 진행 상태

- [x] Step 0. 프로젝트 셋업 (패키지 구조 / build.gradle / docker compose) — [LOG000](docs/LOG000-project-setup.md)
- [x] Step 0-1. 엔티티 및 스키마 DDL 설계 — [LOG001](docs/LOG001-entity-schema.md)
- [x] Step 0-2. 시드 데이터 생성기 (`seed/`) — [LOG002](docs/LOG002-seed-data.md)

### Phase 1 — 실행 계획 읽기
- [x] 1. EXPLAIN ANALYZE 기본 — Seq Scan vs Index Scan
- [x] 2. 인덱스 없는 상태에서 슬로우 쿼리 재현
- [x] 3. 단일 컬럼 인덱스 추가 후 비교 — [LOG003](docs/LOG003-explain-analyze-index.md)
- [x] 4. 복합 인덱스 설계 — 컬럼 순서 — [LOG004](docs/LOG004-composite-index.md)

### Phase 2 — JPA/ORM 레벨 문제
- [x] 5. N+1 문제 재현 — [LOG005](docs/LOG005-n-plus-1.md)
- [x] 6. fetch join으로 해결 — [LOG006](docs/LOG006-fetch-join.md)
- [x] 7. batch size 설정과 fetch join 트레이드오프 — [LOG007](docs/LOG007-batch-size.md)
- [x] 8. QueryDSL로 동일 쿼리 작성 — [LOG008](docs/LOG008-querydsl.md)

### Phase 3 — 복잡한 조회 최적화
- [x] 9. 다중 조건 필터링 (상태 + 기간 + 카테고리) — [LOG009](docs/LOG009-multi-condition-filter.md)
- [x] 10. 커버링 인덱스 — [LOG010](docs/LOG010-covering-index.md)
- [x] 11. 대용량 페이지네이션 — offset 한계, cursor 전환 — [LOG011](docs/LOG011-cursor-pagination.md)
- [x] 12. 집계 쿼리 최적화 — [LOG012](docs/LOG012-aggregate-query.md)

### Phase 4 — 운영 관점
- [x] 13. 슬로우 쿼리 로그 설정 및 분석 — [LOG013](docs/LOG013-slow-query-log.md)
- [x] 14. 인덱스가 write 성능에 미치는 영향 — [LOG014](docs/LOG014-index-write-cost.md)
- [x] 15. VACUUM, ANALYZE — [LOG015](docs/LOG015-vacuum-analyze.md)
- [x] 16. 파티셔닝 (orders, 날짜 기준) — [LOG016](docs/LOG016-partitioning.md)

## 문서

각 단계 완료 시 `docs/LOG###-{제목}.md`로 배경/목표, 시행착오, Q&A, 최종 구성, ADR을 기록한다.
