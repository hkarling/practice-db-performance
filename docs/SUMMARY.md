# 학습 과정 종합 정리

`practice-db-performance` 프로젝트 전체(Step 0 ~ Phase 4 챕터 16)의 요약. 각 항목의
자세한 배경/실험/판단 근거는 링크된 `docs/LOG0##-*.md`에 있다. 각 단계에서 실제로
돌려본 SQL은 [`docs/exploration-queries.sql`](exploration-queries.sql)에 챕터별로
정리돼 있다.

## 프로젝트 개요

- **목표**: Olist 이커머스 스키마(고객/판매자/상품/주문 등 9개 테이블) 기반 대용량
  데이터(customers 100만, orders 500만, order_items 1500만)에서 실행 계획을 읽고,
  인덱스를 설계하고, JPA/QueryDSL 레벨의 N+1·페이지네이션·집계 쿼리를 최적화하는
  전 과정을 단계별로 실습.
- **스택**: Java 21, Spring Boot 4.1.0, Spring Data JPA + Hibernate 7.4.1 + QueryDSL,
  PostgreSQL 17(docker compose 로컬 상시 기동).
- **원칙**: 시드 데이터는 JPA 경로를 안 타고 Python + `COPY`로 직접 적재(LOG002).
  스키마는 `db/schema.sql`이 직접 소유, Hibernate는 `ddl-auto: validate`로 매핑만
  검증(LOG000/LOG001). 모든 실습은 실제 대용량 데이터에서 `EXPLAIN ANALYZE`로
  직접 검증.

## Step 0 — 기반 다지기

| | 내용 |
|---|---|
| [LOG000](LOG000-project-setup.md) | 패키지 구조(hexagonal, 불필요한 depth 없이), build.gradle, docker-compose 로컬 Postgres 상시 기동 전략 |
| [LOG001](LOG001-entity-schema.md) | Olist 9테이블 DDL + JPA 엔티티. FK는 걸되 인덱스는 의도적으로 비워둠(Phase 1 실습용) |
| [LOG002](LOG002-seed-data.md) | Python+Faker+COPY 벌크 로드. COPY 순서=ID 순서를 이용해 FK를 DB 조회 없이 계산. 상태 분포(DELIVERED 70%/SHIPPED 10%/CANCELLED 8%/PROCESSING 7%/REFUNDED 5%) 등 일관성 규칙 부여 |

## Phase 1 — 실행 계획 읽기

| 챕터 | 핵심 결과 | 문서 |
|---|---|---|
| 1~3. EXPLAIN ANALYZE 기본 / 슬로우 쿼리 재현 / 단일 컬럼 인덱스 | `customer_id`(고선택도) 인덱스: **11,270배** 개선. `status`(70%, 저선택도) 인덱스는 옵티마이저가 무시 — `enable_seqscan=off`로 강제 비교해 Bitmap Heap Scan이 실제로 더 느림을 실증(586ms→1186ms) | [LOG003](LOG003-explain-analyze-index.md) |
| 4. 복합 인덱스 설계 — 컬럼 순서 | "최근 배송완료 주문 20건" 쿼리: 인덱스 없음 1300ms → `(status, ordered_at)` 복합 인덱스로 **1,458배**(0.89ms). 컬럼 순서 원칙 정립: **등치(Equality) → 정렬(Sort) → 범위(Range)** | [LOG004](LOG004-composite-index.md) |

## Phase 2 — JPA/ORM 레벨 문제

| 챕터 | 핵심 결과 | 문서 |
|---|---|---|
| 5. N+1 문제 재현 | 주문 20건 조회 후 `customer` 접근 → 22번 쿼리(1+1+20) | [LOG005](LOG005-n-plus-1.md) |
| 6. fetch join으로 해결 | `JOIN FETCH`로 22 → 1번 쿼리. 단, 로컬 환경 실측 시간 차이는 미미 — "쿼리 수는 신뢰할 수 있는 구조적 지표, 실측 시간은 환경(네트워크 지연) 의존적" 교훈 | [LOG006](LOG006-fetch-join.md) |
| 7. batch size vs fetch join | `default_batch_fetch_size=10` — 코드 변경 없이 22 → 4번 쿼리. fetch join(정밀 도구, 항상 1번) vs batch fetch(전역 안전망, N/batch size번) 트레이드오프 정리 | [LOG007](LOG007-batch-size.md) |
| 8. QueryDSL로 동일 쿼리 작성 | JPQL fetch join과 동일 SQL을 QueryDSL로 재현, 타입 안정성 확보. `@Bean` 메서드 파라미터 주입이 `@PersistenceContext` 필드 주입보다 권장 스타일 | [LOG008](LOG008-querydsl.md) |

## Phase 3 — 복잡한 조회 최적화

| 챕터 | 핵심 결과 | 문서 |
|---|---|---|
| 9. 다중 조건 필터링 + JOIN fan-out | QueryDSL 동적 조건(null-safe `BooleanExpression`) 조합. **to-many 조인 시 `LIMIT 20` 요청해도 실제로는 19건만 반환되는(주문 하나 누락) 버그를 실증** — `EXISTS` 서브쿼리로 해결. Hibernate가 Java 리스트에서 중복을 자동 제거해도 `LIMIT`은 원시 행 기준이라 여전히 위험함을 확인 | [LOG009](LOG009-multi-condition-filter.md) |
| 10. 커버링 인덱스 | `order_items(product_id) INCLUDE (order_id)` — 힙 접근(`Heap Fetches: 0`)을 없애 카테고리 필터 쿼리 **6~9배**(2299ms→244ms) 개선. 인덱스 선택도가 아니라 힙 접근 비용 자체가 병목이었음을 규명 | [LOG010](LOG010-covering-index.md) |
| 11. 대용량 페이지네이션 | `OFFSET` 깊은 페이지: 0.1ms → 947ms(**8,776배** 저하, `offset`에 비례). 커서(keyset) 방식 전환 시 페이지 깊이 무관하게 항상 0.9ms대(**1,005배** 개선) | [LOG011](LOG011-cursor-pagination.md) |
| 12. 집계 쿼리 최적화 | `COUNT(*)`/`GROUP BY`는 조건 없인 인덱스가 도움 안 됨(그룹 5개는 HashAggregate가 항상 더 쌈). `ordered_at` 필터 + `(ordered_at) INCLUDE (status)` 커버링 인덱스로 상태별 집계 **8.8배** 개선(681ms→77ms). 선택도(챕터3)+컬럼순서(챕터4)+커버링(챕터10)의 종합 문제였음 | [LOG012](LOG012-aggregate-query.md) |

## Phase 4 — 운영 관점

| 챕터 | 핵심 결과 | 문서 |
|---|---|---|
| 13. 슬로우 쿼리 로그 | `log_min_duration_statement`(개별 로그) vs `pg_stat_statements`(쿼리 패턴별 누적 통계, Postgres 공식 contrib 확장) — 누적 호출 기준으로 봐야 진짜 부하 원인이 보임(단발성 최고 느린 쿼리 ≠ 최다 부하 쿼리). MySQL/Oracle/SQL Server의 대응 도구 비교 | [LOG013](LOG013-slow-query-log.md) |
| 14. 인덱스와 write 성능 | 인덱스 0→4개, 50만 건 INSERT **5.8배** 저하(1.2s→7s). auto-increment PK(순차 값)는 저렴, FK/카테고리 컬럼(무작위 값)은 페이지 분할이 잦아 훨씬 비쌈 | [LOG014](LOG014-index-write-cost.md) |
| 15. VACUUM, ANALYZE | MVCC dead tuple 생성/정리 실측. `pg_stats`의 MCV가 LOG002 시드 분포와 정확히 일치함을 확인. **visibility map 오염 시 Index Only Scan이 최대 52배 느려짐**(78ms→2870ms→55ms, UPDATE→VACUUM 3단계) — 커버링 인덱스의 이점이 VACUUM 상태에 의존함을 실증 | [LOG015](LOG015-vacuum-analyze.md) |
| 16. 파티셔닝 | `ordered_at` 기준 RANGE 파티션 — partition pruning으로 무관한 파티션이 플랜에서 완전히 제외됨(인덱스 없이도 효과). `DROP TABLE` 파티션 삭제 81ms(250만 건, `DELETE` 대비 사실상 즉시) | [LOG016](LOG016-partitioning.md) |

## 관통하는 핵심 원칙

1. **옵티마이저는 항상 비용 기반으로 결정한다** — "인덱스가 있으면 무조건 쓴다"는
   틀린 가정(챕터 1, 3, 9, 12). `enable_seqscan=off` 같은 강제 옵션으로 대안 플랜과
   직접 비교해야 진짜 검증이 된다.
2. **선택도가 인덱스 효과를 좌우한다** — 저선택도 컬럼(챕터 3의 `status` 70%,
   챕터 9의 카테고리 2%)은 단일 컬럼 인덱스로 못 고친다. 힙 접근 비용을 없애는
   커버링 인덱스(챕터 10)나, 조회 패턴 자체를 바꾸는 파티셔닝(챕터 16)처럼 다른
   층위의 해법이 필요할 수 있다.
3. **복합 인덱스 컬럼 순서 = 등치 → 정렬 → 범위**(챕터 4, 12). 최좌측 접두사 규칙은
   `GROUP BY`에도 그대로 적용된다.
4. **"쿼리 수"(구조적 지표)와 "실측 시간"(환경 의존적 지표)은 다르다**(챕터 4, 6,
   7, 15). 로컬호스트처럼 지연이 거의 없는 환경에서는 쿼리 수 차이가 실측 시간에
   안 드러날 수 있다 — 그래도 쿼리 수는 신뢰할 수 있는 지표다.
5. **`LIMIT`은 강력하지만 전제 조건이 있다** — top-N heapsort/lazy evaluation으로
   극적인 이득을 주지만(챕터 4), `OFFSET`은 페이지 깊이에 비례해 느려지고(챕터 11),
   to-many 조인의 fan-out과 만나면 요청한 개수보다 적게 반환하는 조용한 버그가
   된다(챕터 9).
6. **N+1 해결책은 성격이 다르다** — fetch join(정밀, 항상 1번, to-many+페이지네이션
   위험), batch fetch(전역 안전망, N/batch size번, 코드 변경 없음), 커버링 인덱스
   (근본적으로 다른 층위)를 상황에 맞게 조합한다(챕터 5~7, 10).
7. **인덱스는 공짜가 아니다** — 읽기는 빨라지지만 모든 쓰기(INSERT/UPDATE/DELETE)가
   느려지고(챕터 14), VACUUM으로 visibility map을 최신 상태로 유지하지 않으면
   커버링 인덱스의 이점(Index Only Scan)도 사라진다(챕터 15).
8. **운영에서는 "무엇이 문제인지 모르는 상태"에서 시작한다** — 슬로우 쿼리 로그와
   `pg_stat_statements`(챕터 13)가 `EXPLAIN ANALYZE`(무엇을 봐야 할지 이미 아는
   상태를 전제)의 앞단을 채워준다.

## 최종 스키마 / 인덱스 현황

`db/schema.sql` 기준 (9개 테이블):

| 테이블 | 인덱스 | 추가된 챕터 |
|---|---|---|
| `orders` | `orders_pkey`(id) | Step 0-1 |
| | `idx_orders_customer_id` (customer_id) | 챕터 3 |
| | `idx_orders_status_ordered_at` (status, ordered_at DESC) | 챕터 4 |
| | `idx_orders_ordered_at_covering_status` (ordered_at) INCLUDE (status) | 챕터 12 |
| `order_items` | `order_items_pkey`(id) | Step 0-1 |
| | `idx_order_items_product_id_covering` (product_id) INCLUDE (order_id) | 챕터 9→10(교체) |

(그 외 `customers`/`sellers`/`categories`/`products`/`order_payments`/`order_reviews`/
`delivery`는 PK만 유지 — 이번 커리큘럼에서 별도 조회 최적화 대상이 아니었음.)

## 애플리케이션 코드 최종 구성

- `domain`: 9개 엔티티 + `OrderStatus`/`PaymentStatus`/`PaymentType` enum
- `infra`: `OrderRepository`(JPQL fetch join + QueryDSL 커스텀 프래그먼트),
  `OrderQueryRepository`/`Impl`(동적 검색·커서 페이지네이션·fetch join 3종),
  `QuerydslConfig`(`JPAQueryFactory` 빈)
- `test`: `NPlusOneTest`, `FetchJoinTest`, `QuerydslFetchJoinTest`,
  `OrderSearchFanOutTest`, `CursorPaginationTest` — 전부 로컬 Postgres(실제 시드
  데이터) 재사용, `TestcontainersConfiguration`은 `ApplicationTests`(순수 컨텍스트
  로딩 검증)용으로 별도 유지
