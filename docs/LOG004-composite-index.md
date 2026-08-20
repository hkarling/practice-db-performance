# LOG004 — 복합 인덱스 설계 (컬럼 순서)

## 배경 / 목표

Phase 1 챕터 4. `orders` 테이블에 단일 컬럼 인덱스만으로는 해결 안 되는 "필터 + 정렬 +
LIMIT" 조합 쿼리를 복합 인덱스로 최적화하고, 컬럼 순서가 실제로 성능에 어떤 영향을
주는지 확인한다.

## 진행 내용

### 1. 첫 시도 — "특정 고객의 최근 주문" 시나리오는 부적합했음

```sql
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE customer_id = 12345
ORDER BY ordered_at DESC
LIMIT 10;
```

`Limit → Sort → Index Scan(idx_orders_customer_id)` 구조는 나왔지만, 이 고객의 주문이
1건뿐이라 `Sort` 비용이 사실상 0이었다(고객당 평균 주문 5건 수준인 데이터셋 특성상, 이
시나리오로는 Sort 비용이 체감될 만큼 커지지 않음). 시나리오를 "최근 배송완료된 주문
20건 조회"(운영자 대시보드형 쿼리)로 변경.

### 2. 베이스라인 — 인덱스 없이 필터+정렬+LIMIT

```sql
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'DELIVERED'
ORDER BY ordered_at DESC
LIMIT 20;
```

```
Limit  (cost=116689.58..116691.92 rows=20 width=49) (actual time=1273.928..1293.682 rows=20 loops=1)
  ->  Gather Merge  (cost=116689.58..454203.91 rows=2892778 width=49) (actual time=1228.267..1248.018 rows=20 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort  (cost=115689.56..119305.53 rows=1446389 width=49) (actual time=1095.649..1095.652 rows=16 loops=3)
              Sort Key: ordered_at DESC
              Sort Method: top-N heapsort  Memory: 29kB
              ->  Parallel Seq Scan on orders  (cost=0.00..77201.67 rows=1446389 width=49) (actual time=6.292..977.830 rows=1166704 loops=3)
                    Filter: ((status)::text = 'DELIVERED'::text)
                    Rows Removed by Filter: 499963
Planning Time: 0.097 ms
Execution Time: 1300.405 ms
```

**해설**
- `status`에 인덱스가 없으니(챕터 3에서 DROP) 여전히 테이블 전체를 병렬 스캔한다. `LIMIT
  20`이 있어도 **스캔 비용은 전혀 줄지 않는다** — "상위 20건"을 알려면 정렬 기준으로
  미리 정렬돼 있지 않은 한 결국 모든 행을 봐야 하기 때문.
- `Sort Method: top-N heapsort, Memory: 29kB`: `LIMIT`이 있다는 걸 옵티마이저가 알고
  116만 건을 통째로 정렬하는 대신, **크기 20짜리 힙만 유지**하며 스캔한다
  (`O(n log n)` 대신 `O(n log 20)`). 그래서 정렬 자체는 거의 공짜(메모리 29kB).
- **결론**: `LIMIT`은 정렬 비용은 줄여주지만 스캔 비용은 못 줄인다. 병목은 여전히
  "인덱스 없이 테이블 전체를 읽어야 한다"는 점 — `Execution Time`이 챕터 3의 평범한
  Seq Scan(586~700ms대)보다 오히려 더 길다(1300ms).

### 3. 복합 인덱스 추가 — `(status, ordered_at DESC)`

```sql
CREATE INDEX idx_orders_status_ordered_at ON orders (status, ordered_at DESC);  -- 약 6초 소요

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'DELIVERED'
ORDER BY ordered_at DESC
LIMIT 20;
```

```
Limit  (cost=0.43..2.21 rows=20 width=49) (actual time=0.128..0.868 rows=20 loops=1)
  ->  Index Scan using idx_orders_status_ordered_at on orders  (cost=0.43..307785.77 rows=3471333 width=49) (actual time=0.126..0.861 rows=20 loops=1)
        Index Cond: ((status)::text = 'DELIVERED'::text)
Planning Time: 0.485 ms
Execution Time: 0.892 ms
```

**해설**
- **1300.405ms → 0.892ms, 약 1,458배 개선.** `Sort` 노드 자체가 사라졌다 — B-tree가
  `status='DELIVERED'` 그룹을 먼저 묶고, 그 안을 `ordered_at DESC`로 이미 정렬해뒀기
  때문에 그 그룹 맨 앞에서부터 읽기만 하면 원하는 순서 그대로다.
- `cost=0.43..307785.77`인데도 빠른 이유: 이 total cost는 매치되는 350만 건을 **전부**
  읽을 때의 추정치다. 실제로는 `Limit`이 20건만 요구하니 실행기가 인덱스를 앞에서부터
  읽다가 20건 채우는 순간 멈춘다(lazy evaluation) — `actual rows=20`이 그 증거.
- **반전**: 챕터 3에서 `status` 단일 컬럼 인덱스는 선택도가 낮아 "죽은 인덱스"였다.
  같은 `status` 컬럼이 복합 인덱스의 앞자리로 들어가자 이번엔 완전히 다른 이유(정렬
  순서 제공)로 결정적인 역할을 한다 — 인덱스의 유용성은 컬럼 선택도만이 아니라
  **쿼리 패턴(필터+정렬+LIMIT 조합)**에 달려있다.

### 4. 희귀 값(`REFUNDED`, 5%)으로 재검증 — 정방향은 선택도 무관하게 빠름

```sql
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'REFUNDED'
ORDER BY ordered_at DESC
LIMIT 20;
```

```
Limit  (cost=0.43..14.70 rows=20 width=49) (actual time=0.236..1.114 rows=20 loops=1)
  ->  Index Scan using idx_orders_status_ordered_at on orders  (cost=0.43..185352.59 rows=259833 width=49) (actual time=0.235..1.108 rows=20 loops=1)
        Index Cond: ((status)::text = 'REFUNDED'::text)
Execution Time: 1.135 ms
```

**해설**: `REFUNDED`(약 5%)로 바꿔도 여전히 빠르다(1.135ms) — `Index Cond`로 그 그룹을
바로 찾아 앞에서 20개만 읽었기 때문에 선택도와 무관하게 동작한다.

### 5. 컬럼 순서를 반대로(`(ordered_at DESC, status)`) — 대조 실험

```sql
DROP INDEX idx_orders_status_ordered_at;
CREATE INDEX idx_orders_ordered_at_status ON orders (ordered_at DESC, status);

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'REFUNDED'
ORDER BY ordered_at DESC
LIMIT 20;
```

```
Limit  (cost=0.43..26.63 rows=20 width=49) (actual time=0.071..0.112 rows=20 loops=1)
  ->  Index Scan using idx_orders_ordered_at_status on orders  (cost=0.43..340314.10 rows=259833 width=49) (actual time=0.070..0.109 rows=20 loops=1)
        Index Cond: ((status)::text = 'REFUNDED'::text)
Execution Time: 0.125 ms
```

**해설**
- 예상과 다르게 실측 시간은 오히려 이쪽이 더 빨랐다(0.125ms vs 1.135ms). 이유를
  분석해보면:
  - `Index Cond`로 표시된 이유: `Index Cond`/`Filter`의 진짜 기준은 "스캔 범위를
    좁혔는가"가 아니라 **"힙 접근 없이 인덱스 튜플만으로 조건을 확인할 수 있는가"**다.
    `status`가 이 인덱스에 포함된 컬럼이라 힙 없이 확인 가능해 `Index Cond`로 뜬 것 —
    다만 실제 **탐색 시작 위치를 좁혀주진 못한다**(`ordered_at`엔 조건이 없으니 인덱스
    맨 앞부터 순서대로 훑으며 `status`를 튜플마다 확인).
  - `REFUNDED`가 5%라 20건을 채우려면 평균 `20 ÷ 0.05 ≈ 400`개 인덱스 항목을 훑어야
    하는데, 그 정도는 순차 페이지 읽기로도 충분히 빠르고(테이블을 반복 조회해 버퍼
    캐시에 이미 올라와 있기도 했음) `LIMIT`이 절대적인 작업량 자체를 작게 묶어버려
    체감 차이가 안 났다.
  - **하지만 옵티마이저의 total cost 추정치(LIMIT 없이 끝까지 다 읽는다면의 비용)는
    정확히 구조적 차이를 반영한다**: 정방향 `185352.59` vs 역방향 `340314.10`(약 1.8배).
    `LIMIT`이 훨씬 크거나 조건이 훨씬 희귀했다면 실측 시간에서도 이 차이가 그대로
    드러났을 것.

### 6. 일반 원칙 — 등치(Equality) → 정렬(Sort) → 범위(Range)

쿼리의 조건을 아래 세 종류로 분류해 이 순서 그대로 인덱스 컬럼을 배치한다.

1. **등치(`=`) 조건 컬럼 → 항상 맨 앞.** B-tree에서 정확히 하나의 부분 그룹으로 스캔
   범위를 좁혀주므로, 뒤따르는 컬럼들이 "그 그룹 안에서"라는 좁은 범위 위에서 의미를
   갖게 하려면 반드시 앞에 와야 한다.
2. **정렬(`ORDER BY`) 전용 컬럼 → 등치 컬럼 바로 다음.** 등치로 좁힌 그룹 안에서 이미
   정렬된 상태를 얻어 `Sort` 노드를 없앤다.
3. **범위(`>`, `<`, `BETWEEN`) 조건 컬럼 → 맨 뒤.** 범위 조건 자체가 이미 "연속 구간"을
   스캔하게 만들어서, 그 안에서는 다른 컬럼의 정렬 보장이 깨지기 때문.

등치 조건이 앞에 없으면 뒤따르는 컬럼은 "전체를 순서대로 훑으며 걸러내는" 역할로
전락한다 — 스캔 시작 위치 자체를 못 좁히기 때문. 이번 실험(등치 `status` + 정렬
`ordered_at`)에서 정방향 `(status, ordered_at)`이 정답이었던 이유가 이것.

## 시행착오 / Q&A

**Q. 처음 시나리오(고객별 주문 정렬)에서 왜 `Sort` 비용이 안 보였나?**
A. 데이터셋이 고객당 평균 주문 5건 수준이라 정렬 대상 자체가 너무 작았다. 복합 인덱스의
효과를 체감하려면 조건에 맞는 행 수가 충분히 많은 시나리오가 필요하다 — "최근 배송완료
주문 20건"처럼 전체 5백만 건 중 다수(70%)가 매치되는 케이스로 바꿔서 확인.

**Q. non-leading 컬럼 조건인데 왜 `Filter`가 아니라 `Index Cond`로 뜨나?**
A. `Index Cond`/`Filter` 구분은 "탐색 범위를 좁혔는가"가 아니라 "힙 접근 없이 인덱스
데이터만으로 조건을 확인할 수 있는가" 기준이다. 인덱스에 포함된 컬럼이면 위치와
무관하게 `Index Cond`로 표시될 수 있다 — 다만 이게 곧 "탐색 범위를 좁혔다"는 뜻은
아니므로 이 표시만으로 인덱스가 효율적으로 쓰였다고 오해하면 안 된다.

**Q. 역방향 인덱스가 실측으로 안 느렸는데, 그럼 순서가 안 중요한 거 아닌가?**
A. `LIMIT`이 절대적인 작업량을 작게 묶어버려서 이번 스케일(LIMIT 20, 선택도 5%)에서는
체감이 안 됐을 뿐이다. 옵티마이저의 total cost 추정치(1.8배 차이)가 구조적 차이를
정확히 반영하고 있고, `LIMIT`을 키우거나 조건을 더 희귀하게 하면 실측 시간에서도
드러난다. 원리(등치 → 정렬 → 범위)를 알고 있으면 매번 실측으로 검증할 필요 없이 인덱스
설계 단계에서 미리 판단할 수 있다.

## 최종 구성

`orders` 테이블 인덱스:

| 인덱스 | 컬럼 | 용도 |
|---|---|---|
| `orders_pkey` | `id` | PK |
| `idx_orders_customer_id` | `customer_id` | 고선택도 등치 조회 (챕터 3) |
| `idx_orders_status_ordered_at` | `status, ordered_at DESC` | 등치(`status`) + 정렬(`ordered_at`) + LIMIT 조합 (챕터 4) |

`db/schema.sql`에 반영 완료.

## ADR

### Decision
- 복합 인덱스 컬럼 순서는 **등치(Equality) → 정렬(Sort) → 범위(Range)** 순으로 설계한다.
  이번 챕터에서 실측(정방향 total cost 185352.59 vs 역방향 340314.10)으로 확인.

### Drivers
- 단일 컬럼 인덱스로는 "필터 + 정렬 + LIMIT" 조합 쿼리(운영 대시보드류)를 최적화할 수
  없음을 챕터 3 이후 자연스럽게 확인할 필요가 있었음

### Alternatives considered
- 역방향(`ordered_at, status`) 인덱스 — 실측 시간은 이번 스케일에서 비슷했지만
  옵티마이저 cost 추정치상 구조적으로 더 비쌈이 확인되어 기각, 실험 후 DROP

### Consequences
- `idx_orders_status_ordered_at`가 `db/schema.sql`에 반영되어 스키마 재적용 시 자동
  생성됨
- "등치 → 정렬 → 범위" 원칙은 이후 챕터(9. 다중 조건 필터링, 10. 커버링 인덱스)에서도
  계속 적용

### Follow-ups
- Phase 2 — JPA/ORM 레벨 문제 (챕터 5: N+1 문제 재현)로 이동
