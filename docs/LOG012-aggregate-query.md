# LOG012 — 집계 쿼리 최적화

## 배경 / 목표

Phase 3 챕터 12(마지막). `COUNT(*)`와 `GROUP BY` 집계 쿼리의 비용 특성을 확인하고,
필터 조건과 인덱스 컬럼 순서가 집계 성능에 어떤 영향을 주는지 단계적으로
검증한다.

## 개념

### `COUNT(*)`는 지름길이 없다
MySQL(InnoDB)과 달리 Postgres는 테이블의 정확한 행 수를 미리 유지해두지 않는다 —
MVCC 때문에 트랜잭션마다 "보이는 행"이 다를 수 있어서, `COUNT(*)`는 매번 조건에
맞는 행을 실제로 세야 한다. `LIMIT`처럼 중간에 멈출 방법도 없다(정확한 개수가
나오려면 끝까지 세야 하므로) — 매치되는 행 수만큼 비용이 그대로 든다.

### `GROUP BY`의 두 가지 집계 전략
- **HashAggregate**: 그룹 키를 해시 테이블에 올려두고 스캔하면서 누적. 정렬이
  필요 없어 보통 빠르지만 그룹 수가 많으면 메모리를 많이 쓴다.
- **GroupAggregate**: 정렬된(또는 인덱스로 정렬 순서가 보장된) 데이터를 순서대로
  훑으면서 그룹이 바뀔 때마다 집계. 인덱스가 이미 그 순서로 정렬돼 있으면 별도
  정렬 없이 바로 쓸 수 있다.

### 집계에서도 최좌측 접두사 규칙은 그대로 적용된다
챕터 4에서 배운 규칙이 집계 쿼리에도 동일하게 적용된다 — 복합 인덱스
`(A, B)`는 `A`에 조건이 없으면 `B`만으로 스캔 범위를 못 좁힌다. `GROUP BY`도
예외가 아니다.

## 진행 내용

### 1. 베이스라인 — `COUNT(*)` (조건 없음)

```sql
EXPLAIN ANALYZE SELECT COUNT(*) FROM orders;
```
```
Finalize Aggregate  (cost=78201.88..78201.89 rows=1 width=8) (actual time=373.314..392.193 rows=1 loops=1)
  ->  Gather  (cost=78201.67..78201.88 rows=2 width=8) (actual time=373.307..392.186 rows=3 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate  (cost=77201.67..77201.68 rows=1 width=8) (actual time=310.506..310.507 rows=1 loops=3)
              ->  Parallel Seq Scan on orders  (cost=0.00..71993.33 rows=2083333 width=0) (actual time=0.023..191.720 rows=1666667 loops=3)
Planning Time: 0.106 ms
Execution Time: 392.242 ms
```

**해설**: `width=0`이 핵심 — `COUNT(*)`는 실제 컬럼 값을 읽을 필요가 없어서
(존재/가시성만 확인) 힙에서 컬럼 데이터를 아예 안 가져온다. 워커 3개(리더+2)가
500만 건을 나눠 세고 합산한다. 인덱스가 있어도 "매치되는 행 전부를 세야" 하니
지름길이 없다 — 392ms는 500만 건을 순회하는 순수 비용.

### 2. `GROUP BY status` (조건 없음) — 인덱스가 있는데도 안 씀

```sql
EXPLAIN ANALYZE SELECT status, COUNT(*) FROM orders GROUP BY status;
```
```
Finalize GroupAggregate  (cost=83410.13..83411.40 rows=5 width=17) (actual time=679.943..681.157 rows=5 loops=1)
  Group Key: status
  ->  Gather Merge  (cost=83410.13..83411.30 rows=10 width=17) (actual time=679.930..681.144 rows=15 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort  (cost=82410.11..82410.12 rows=5 width=17) (actual time=637.837..637.839 rows=5 loops=3)
              Sort Key: status
              Sort Method: quicksort  Memory: 25kB
              ->  Partial HashAggregate  (cost=82410.00..82410.05 rows=5 width=17) (actual time=637.764..637.766 rows=5 loops=3)
                    Group Key: status
                    Batches: 1  Memory Usage: 24kB
                    ->  Parallel Seq Scan on orders  (cost=0.00..71993.33 rows=2083333 width=9) (actual time=0.018..168.684 rows=1666667 loops=3)
Planning Time: 1.537 ms
Execution Time: 681.234 ms
```

**해설**
- **392ms → 681ms, 같은 500만 건인데 더 느려졌다.** `width=9` — 이번엔 `status`
  값을 실제로 읽어야(그룹핑 기준) 하니 컬럼 데이터를 가져온다. 컬럼 값을
  읽는(deform) 비용이 추가된 것.
- 기존 `idx_orders_status_ordered_at`(`status, ordered_at`)이 있는데도 안
  쓰였다. `status`는 값이 5개뿐이라, 인덱스로 정렬 순서를 따라가는 것보다
  스캔하면서 해시 테이블 5칸에 카운트를 누적(`HashAggregate`)하는 게 훨씬
  싸다 — 그룹 수가 이렇게 적으면 정렬의 이점이 없다. 게다가 `WHERE` 조건이
  없어(전체 집계) 인덱스로 걸러낼 것도 없다 — 어차피 500만 건을 다 봐야 하니
  병렬 처리에 유리한 Seq Scan이 낫다는 판단.
- 최상위 노드가 `Finalize GroupAggregate`라 인덱스 기반 정렬 스캔처럼 보이지만,
  실제로는 "워커별 해시 집계 → 그 결과(워커당 5행)만 정렬해서 병합"하는 구조다.
  인덱스의 정렬 순서를 활용한 게 아니라 병렬 워커 결과를 합치기 위한 작은
  정렬일 뿐.

### 3. 잘못된 시도 — `created_at` 필터

```sql
EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders
WHERE created_at > '2023-01-01' GROUP BY status;
```
```
->  Parallel Seq Scan on orders  (... width=9 ...) (actual rows=1666667 loops=3)
      Filter: (created_at > '2023-01-01 00:00:00+00'::timestamp with time zone)
Execution Time: 1140.653 ms
```

**해설**: 두 가지 문제가 겹쳤다.
1. `created_at`은 시드 적재 시점(전부 최근)이라 이 조건이 사실상 전체 행을 다
   통과시킨다 — `Filter` 적용 후에도 `rows=1666667`(필터 전과 동일). 아무것도
   못 걸러내고 필터 검사 오버헤드만 추가돼 오히려 더 느려졌다(1140ms).
2. `created_at`은 `idx_orders_status_ordered_at`(`status, ordered_at`)에
   아예 없는 컬럼이라, 설령 선택도가 좋았어도 이 인덱스를 못 썼다. 실제 "주문
   일자"는 `ordered_at`이다.

### 4. 올바른 컬럼(`ordered_at`), 그러나 인덱스 순서가 안 맞음

```sql
EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders
WHERE ordered_at > '2025-12-01' GROUP BY status;
```
```
->  Parallel Seq Scan on orders  (... width=9 ...) (actual rows=70563 loops=3)
      Filter: (ordered_at > '2025-12-01 00:00:00+00'::timestamp with time zone)
      Rows Removed by Filter: 1596104
Execution Time: 314.959 ms
```

**해설**: 이번엔 필터 자체는 유효했다(21만 건/500만 건, 약 4.2%로 선택도 좋음)
— 그런데도 여전히 `Parallel Seq Scan`(인덱스 미사용)이다. **최좌측 접두사
규칙**이 여기서도 그대로 적용된다: `idx_orders_status_ordered_at`은
`(status, ordered_at)` 순서라 `status`가 맨 앞인데, 이 쿼리는 `status`에
조건이 없다(오히려 `status`로 그룹핑만 함) — 앞 컬럼에 등치 조건이 없으니
뒤 컬럼(`ordered_at`)만으로는 스캔 범위를 못 좁힌다. 필터링된 결과가 작아서
실행 시간은 줄었지만(314.959ms), 이건 인덱스 덕분이 아니라 그냥 결과 집합이
작아서다.

### 5. 올바른 인덱스 — `(ordered_at) INCLUDE (status)`

이 쿼리에 필요한 건 반대 방향 인덱스다: `ordered_at`이 범위 조건(맨 앞),
`status`는 결과로만 필요하니 커버링(`INCLUDE`, 챕터 10)으로.

```sql
CREATE INDEX idx_orders_ordered_at_covering_status
  ON orders (ordered_at) INCLUDE (status);  -- 약 3초 소요
```

```
Finalize GroupAggregate  (cost=8211.13..8212.40 rows=5 width=17) (actual time=77.064..77.339 rows=5 loops=1)
  Group Key: status
  ->  Gather Merge  (cost=8211.13..8212.30 rows=10 width=17) (actual time=77.055..77.328 rows=15 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort  (cost=7211.11..7211.12 rows=5 width=17) (actual time=39.012..39.013 rows=5 loops=3)
              Sort Key: status
              Sort Method: quicksort  Memory: 25kB
              ->  Partial HashAggregate  (cost=7211.00..7211.05 rows=5 width=17) (actual time=38.958..38.960 rows=5 loops=3)
                    Group Key: status
                    Batches: 1  Memory Usage: 24kB
                    ->  Parallel Index Only Scan using idx_orders_ordered_at_covering_status on orders  (cost=0.43..6763.95 rows=89411 width=9) (actual time=0.044..25.643 rows=70563 loops=3)
                          Index Cond: (ordered_at > '2025-12-01 00:00:00+00'::timestamp with time zone)
                          Heap Fetches: 0
Planning Time: 0.331 ms
Execution Time: 77.382 ms
```

**해설**
- **314.959ms → 77.382ms, 약 4배 개선**(조건 없는 베이스라인 681ms 대비로는
  약 8.8배).
- `Parallel Index Only Scan ... Index Cond: (ordered_at > ...) Heap Fetches: 0`:
  예측대로 `ordered_at` 조건으로 인덱스 범위를 좁히고, `status`도 힙 접근 없이
  인덱스에서 바로 얻었다. `Rows Removed by Filter`도 사라졌다 — 21만 건만 만지고
  나머지 480만 건은 아예 안 봤다는 뜻.
- **이 챕터 전체가 결국 Phase 3의 종합 문제였다**: 선택도(챕터 3) + 컬럼 순서/
  최좌측 접두사(챕터 4) + 커버링 인덱스(챕터 10)가 전부 다시 등장했다. 인덱스
  하나 잘못 만들면(순서가 안 맞으면) 아무리 선택도가 좋아도 안 쓰인다는 걸
  다시 한번 확인.

## 시행착오 / Q&A

**Q. `idx_orders_status_ordered_at`와 `idx_orders_ordered_at_covering_status`
둘 다 유지해야 하나?**
A. 그렇다 — 서로 다른 쿼리 패턴을 지원한다.
- `idx_orders_status_ordered_at`(`status, ordered_at`): "특정 상태의 주문을
  최근순으로"(챕터 4의 원래 목적) — `status` 등치 조건이 있는 쿼리용.
- `idx_orders_ordered_at_covering_status`(`ordered_at` INCLUDE `status`):
  "특정 기간의 주문을 상태별로 집계"처럼 `status` 조건 없이 `ordered_at`만
  필터링하는 쿼리용.

둘은 서로 대체 관계가 아니라 상호 보완 관계.

## 최종 구성

`orders` 테이블 인덱스 (최종):

| 인덱스 | 컬럼 | 용도 |
|---|---|---|
| `orders_pkey` | `id` | PK, 커서 페이지네이션(챕터 11) |
| `idx_orders_customer_id` | `customer_id` | 고선택도 등치 조회(챕터 3) |
| `idx_orders_status_ordered_at` | `status, ordered_at DESC` | 상태 등치 + 정렬(챕터 4) |
| `idx_orders_ordered_at_covering_status` | `ordered_at` INCLUDE `status` | 기간 필터 + 상태별 집계(챕터 12) |

`db/schema.sql`에 반영 완료.

## ADR

### Decision
- 집계 쿼리 최적화 시 "그룹 수가 적으면 인덱스보다 HashAggregate가 나을 수
  있다"는 걸 전제로, 인덱스는 **그룹핑 자체가 아니라 필터링(WHERE 조건)을
  좁히는 용도**로 설계한다. 필터 조건 컬럼이 인덱스 맨 앞에 오고, 그룹핑/출력에만
  필요한 컬럼은 `INCLUDE`로 커버링하는 패턴을 표준으로 삼는다.

### Drivers
- `COUNT(*)`/`GROUP BY`가 인덱스 유무와 무관하게 여전히 선택도와 최좌측 접두사
  규칙의 지배를 받는다는 걸 실측으로 재확인할 필요가 있었음

### Alternatives considered
- `created_at` 필터 — 실제 업무 컬럼이 아니라 시드 적재 시점이라 선택도가 없어
  기각(이 프로젝트 데이터 특성에 따른 실수, 실무에서는 컬럼 의미를 먼저
  확인해야 한다는 교훈)

### Consequences
- 인덱스가 4개로 늘어남 — 챕터 14(인덱스가 write 성능에 미치는 영향)에서
  이 누적된 인덱스들의 쓰기 비용을 종합적으로 다룰 예정
- Phase 3(복잡한 조회 최적화) 완료

### Follow-ups
- Phase 4 — 운영 관점: 챕터 13(슬로우 쿼리 로그), 14(인덱스와 write 성능),
  15(VACUUM/ANALYZE), 16(파티셔닝)
