# practice-db-performance

## 왜 이 프로젝트를 시작했는가

과거에 쿼리를 자주 다루던 시기가 있었지만, 이후 플랫폼/인프라 중심 업무를 하며 쿼리 튜닝 감각에서 멀어졌다. 이번 프로젝트는 그 감각을 다시 끌어올리는 첫걸음이자, 실제 이커머스 규모의 데이터(Olist 스키마 기반 주문 500만·주문상품 1500만 건)를 직접 적재하고 문제를 재현·해결하며 JPA·QueryDSL 같은 ORM 레벨 이해까지 확장하는 것을 목표로 한다.

**Olist 스키마를 택한 이유**: 고객/판매자/상품/주문이 서로 다중 관계로 얽혀있어 실제 조인 복잡도와 N+1 발생 조건을 실무와 가깝게 재현할 수 있다.

**500만/1500만 규모를 택한 이유**: 이 정도 규모부터 인덱스 없이는 Seq Scan이 수 초 단위로 느려져 성능 차이를 명확히 관찰할 수 있었다.

## 학습 목표

이 프로젝트를 통해 다음을 직접 검증하고 체득하는 것을 목표로 한다:

- 실행 계획(EXPLAIN ANALYZE)을 읽고 병목 지점을 특정할 수 있다
- 인덱스를 읽기 성능과 쓰기 비용의 트레이드오프 관점에서 설계할 수 있다
- N+1 등 ORM 레벨 문제를 발생 원인 기준으로 이해하고, 상황에 맞는 해결책을 선택할 수 있다
- 대용량 테이블 운영(파티셔닝, VACUUM, 슬로우 쿼리 모니터링) 관점까지 시야를 넓힌다

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
