# LOG016 — 파티셔닝 (orders, 날짜 기준)

## 배경 / 목표

Phase 4 챕터 16(마지막). `ordered_at` 기준 RANGE 파티셔닝을 격리된 테스트
테이블에 적용해, **파티션 프루닝**(관련 없는 파티션을 스캔에서 아예
제외)과 **파티션 단위 즉시 삭제**(`DROP TABLE`)를 직접 확인한다.

## 개념

### 파티셔닝이란
큰 테이블을 물리적으로 여러 조각(파티션)으로 나눠 저장하면서, 쿼리는 여전히
하나의 논리적 테이블처럼 다루게 하는 기능. `orders`라면 `ordered_at` 기준으로
연도별/월별 파티션을 나누는 식이다.

### Partition Pruning
`WHERE ordered_at > '...'` 같은 조건이 있으면, 옵티마이저가 **계획 수립
단계에서 관련 없는 파티션을 스캔 후보에서 아예 제외**한다. 인덱스가 "같은
테이블 안에서 필요한 행만 찾아가는" 방식이라면, 파티셔닝은 "애초에 필요한
조각만 본다"는 더 근본적인 방식이다 — 인덱스가 전혀 없어도 효과가 있다.

### 실무에서 진짜 힘을 발휘하는 지점
단일 쿼리 속도보다 오히려 이쪽이 크다:
- **데이터 수명주기 관리**: "N년 지난 데이터는 삭제"를 대량 `DELETE`(수백만 건
  스캔+삭제, dead tuple 대량 발생, `VACUUM` 부담 — 챕터 14~15에서 본 그 비용)
  대신 `DROP TABLE 파티션명`으로 **거의 즉시** 처리할 수 있다.
- **VACUUM/ANALYZE 단위가 작아짐**: 파티션마다 독립적으로 유지보수돼서, 거대한
  테이블 하나를 통째로 다루는 부담이 줄어든다.
- 이미 좋은 인덱스(챕터 12·15의 `idx_orders_ordered_at_covering_status`)가
  있는 쿼리엔 파티셔닝이 극적인 추가 이득을 안 줄 수도 있다 — "완벽한 인덱스
  설계의 대체재"가 아니라 "다른 층위의 안전망"에 가깝다.

### 기존 테이블을 그대로 파티션 테이블로 바꿀 수 없다
Postgres는 이미 존재하는 일반 테이블을 파티션 테이블로 바로 전환하는 기능이
없다 — 새로 파티션 테이블을 만들고 데이터를 옮겨야 한다. `orders`는
`order_items`/`order_payments`/`order_reviews`/`delivery`가 FK로 참조하고
있고 15개 챕터의 실습 기반이라, 챕터 14와 마찬가지로 **격리된 테스트
테이블**로 실습했다.

### 파티션 키는 유니크 제약에 포함돼야 한다
파티션 테이블의 PK(및 모든 유니크 제약)는 파티션 키(`ordered_at`)를 반드시
포함해야 한다 — 그래야 어느 파티션에서 유니크성을 검사해야 할지 애매해지지
않는다. 그래서 `id` 단일 PK 대신 `(id, ordered_at)` 복합 PK를 썼다.

## 진행 내용

### 1. 파티션 테이블 생성

```sql
CREATE TABLE orders_partition_test (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    customer_id BIGINT      NOT NULL,
    status      VARCHAR(20) NOT NULL,
    ordered_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (id, ordered_at)
) PARTITION BY RANGE (ordered_at);

CREATE TABLE orders_partition_test_2024 PARTITION OF orders_partition_test
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE orders_partition_test_2025 PARTITION OF orders_partition_test
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
```

### 2. 데이터 적재

```sql
INSERT INTO orders_partition_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders;
```

500만 건, 약 12초 소요. Postgres가 각 행의 `ordered_at` 값을 보고 알맞은
파티션(`_2024` 또는 `_2025`)에 자동으로 나눠 담는다 — 애플리케이션/쿼리
입장에서는 여전히 `orders_partition_test` 하나로 보인다.

### 3. Partition Pruning 확인

```sql
EXPLAIN ANALYZE
SELECT * FROM orders_partition_test WHERE ordered_at > '2025-12-01';
```
```
Seq Scan on orders_partition_test_2025 orders_partition_test  (cost=0.00..39660.78 rows=508207 width=82) (actual time=0.624..499.032 rows=211689 loops=1)
  Filter: (ordered_at > '2025-12-01 00:00:00+00'::timestamp with time zone)
  Rows Removed by Filter: 2282942
Planning Time: 8.196 ms
Execution Time: 507.845 ms
```

**해설**
- **`Append` 노드조차 없이 `orders_partition_test_2025` 파티션 하나만
  스캔했다.** `orders_partition_test_2024`는 플랜에 아예 등장하지 않는다 —
  옵티마이저가 계획 수립 단계에서 "`ordered_at > '2025-12-01'`이면 2024년
  파티션(`[2024-01-01, 2025-01-01)` 범위)엔 매치될 리가 없다"는 걸 판단하고
  아예 스캔 후보에서 제외했다.
- 2025 파티션 총 행 수는 `211689(매치) + 2282942(제거) = 2,494,631`건 — 전체
  500만 건의 약 절반. 인덱스가 전혀 없는 `Seq Scan`인데도 507.845ms에 끝났다
  — 파티셔닝을 안 했다면 500만 건 전체를 다 훑어야 했을 것이고(챕터 12·15의
  순수 Seq Scan 500만 건 기준 900~1200ms대와 비교하면 대략 절반 시간), 이
  절감은 **물리적으로 관련 없는 데이터 자체를 안 보기 때문**이다.

### 4. 즉시 삭제

```sql
DROP TABLE orders_partition_test_2024;
```

약 81ms. 250만 건이 들어있던 파티션이 사실상 즉시 사라졌다 — `DELETE`로
같은 양을 지웠다면 dead tuple 250만 건 발생 + 인덱스 유지보수(챕터 14) +
후속 `VACUUM`까지 겹쳐 훨씬 오래 걸렸을 것. `DROP TABLE`은 파일 시스템
수준에서 파티션을 통째로 제거하는 메타데이터 작업이라 데이터 크기와 거의
무관하게 빠르다.

### 5. 정리

```sql
DROP TABLE orders_partition_test;
```

남은 `orders_partition_test_2025`까지 부모 테이블과 함께 정리 — 실제
`orders` 스키마엔 변경 없음.

## 최종 구성

이번 챕터는 격리된 테스트 테이블(`orders_partition_test` 및 그 파티션들)로만
실습했고 전부 정리(DROP)했다 — `db/schema.sql`이나 실제 `orders` 테이블
구조 변경 없음.

## ADR

### Decision
- 이 프로젝트(`orders` 500만 건 규모, 단일 인스턴스 학습 환경)에서는 실제
  파티셔닝을 적용하지 않는다 — 이미 챕터 12·15에서 만든 커버링 인덱스가
  날짜 필터 쿼리를 충분히 빠르게 만들었고, FK로 얽힌 5개 테이블(`order_items`
  등)까지 함께 파티셔닝하려면 스키마 전체를 다시 설계해야 해서 이번 학습
  범위를 넘어선다. 다만 "언젠가 이 테이블이 훨씬 커지거나, 오래된 데이터를
  주기적으로 삭제해야 하는 요구가 생기면" 파티셔닝이 유력한 선택지라는 걸
  원리 수준에서 확인해뒀다.

### Drivers
- 인덱스만으로는 못 푸는 문제(대량 삭제의 비용, 유지보수 단위 축소)가
  있다는 걸 챕터 14·15의 결과와 대비해 확인할 필요가 있었음

### Alternatives considered
- 실제 `orders` 테이블을 파티션 테이블로 전환 — Postgres가 기존 테이블의
  직접 전환을 지원하지 않고, FK 의존 관계와 15개 챕터의 실습 기반을 깨뜨릴
  위험이 커서 기각. 격리된 테스트 테이블로 원리만 검증하는 쪽을 택함

### Consequences
- 파티셔닝은 "인덱스보다 무조건 낫다"가 아니라 **다른 문제(데이터 수명주기,
  유지보수 단위)를 푸는 도구**라는 걸 명확히 함 — 이미 좋은 인덱스가 있는
  쿼리 하나의 속도만 보고 파티셔닝 도입을 판단하면 안 됨

### Follow-ups
- 없음 — **Phase 1~4, 전체 16챕터 커리큘럼 완료**

---

## 커리큘럼 마무리 메모

Step 0(프로젝트 셋업)부터 챕터 16(파티셔닝)까지 — Postgres 실행 계획 읽기,
JPA/ORM N+1과 fetch join/batch size, QueryDSL 동적 쿼리, 복잡한 다중 조건
조회와 JOIN fan-out, 커버링 인덱스, 커서 페이지네이션, 집계 쿼리, 그리고
운영 관점(슬로우 쿼리 로그, 인덱스의 write 비용, VACUUM/ANALYZE, 파티셔닝)까지
전부 실제 500만~1500만 건 규모 데이터에서 `EXPLAIN ANALYZE`로 직접 검증하며
진행했다. `docs/LOG000`~`LOG016` 17개 문서에 각 단계의 배경/실행/결과/판단이
전부 기록돼 있다.
