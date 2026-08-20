# LOG010 — 커버링 인덱스

## 배경 / 목표

Phase 3 챕터 10. LOG009에서 못 푼 문제 — 카테고리 필터가 `order_items`(1500만 건)의
약 2%만 매치하는데도 단일 컬럼 인덱스(`idx_order_items_product_id`)가 무시되고
`Parallel Seq Scan`이 선택됐던 것 — 를 **커버링 인덱스**로 다시 풀어본다.

## 개념

### 커버링 인덱스(Covering Index) / Index Only Scan
쿼리가 필요로 하는 컬럼을 인덱스 자체에 다 담아둬서, **힙(테이블 본체)에 접근할
필요가 없게** 만드는 인덱스. 챕터 1에서 예고했던 Index Only Scan이 실제로
동작하는 조건이다.

- 일반 Index Scan: 인덱스로 위치를 찾은 뒤, 실제 데이터를 얻으려면 힙 페이지에
  한 번 더 접근한다(랜덤 I/O).
- Index Only Scan: 필요한 컬럼이 전부 인덱스 안에 있으면 힙 접근 없이 인덱스만으로
  끝난다.

Postgres는 `INCLUDE` 절로 "검색 조건/정렬에는 안 쓰지만 결과로 필요한 컬럼"을
인덱스에 추가로 저장할 수 있게 해준다:

```sql
CREATE INDEX idx_xxx ON table (검색조건_컬럼) INCLUDE (같이_필요한_컬럼);
```

`INCLUDE`로 넣은 컬럼은 B-tree의 정렬 키가 아니라 리프 페이지에 데이터로만
저장된다 — 검색/정렬에는 관여하지 않고 오직 "힙 접근 없이 바로 돌려주기" 위한
용도.

## 진행 내용

### 1. LOG009에서 남은 문제 재점검

챕터 9에서 `idx_order_items_product_id`(`product_id` 단일 컬럼)로도 플랜이 안
바뀌었던 진짜 이유를 다시 생각해보면: 이 인덱스로 4155개 상품 각각을 조회하면,
매치되는 `order_items` 약 75건마다 **`order_id`를 얻기 위해 힙에 한 번씩
접근**해야 한다 — 총 약 31만 번의 랜덤 힙 접근. 옵티마이저가 "차라리 순차
스캔"이라고 판단한 진짜 비용이 여기 있었을 가능성이 높다.

### 2. 커버링 인덱스 생성

```sql
CREATE INDEX idx_order_items_product_id_covering
  ON order_items (product_id) INCLUDE (order_id);  -- 약 3초 소요
```

### 3. 결과 — 플랜 구조 자체가 바뀜

```
Limit  (cost=40563.16..40586.90 rows=20 width=137) (actual time=236.597..243.744 rows=20 loops=1)
  ->  Nested Loop  (cost=40563.16..420960.58 rows=320466 width=137) (actual time=236.596..243.738 rows=20 loops=1)
        ->  Merge Semi Join  (cost=40562.74..274595.81 rows=320466 width=49) (actual time=236.526..242.900 rows=20 loops=1)
              Merge Cond: (o1_0.id = oi1_0.order_id)
              ->  Index Scan Backward using orders_pkey on orders o1_0  (cost=0.43..181011.43 rows=5000000 width=49) (actual time=0.007..0.109 rows=308 loops=1)
              ->  Gather Merge  (cost=40558.58..77082.27 rows=320466 width=8) (actual time=236.501..242.750 rows=20 loops=1)
                    Workers Planned: 1
                    Workers Launched: 1
                    ->  Sort  (cost=39558.57..40029.84 rows=188509 width=8) (actual time=215.430..215.484 rows=1030 loops=2)
                          Sort Key: oi1_0.order_id DESC
                          Sort Method: external merge  Disk: 2064kB
                          Worker 0:  Sort Method: quicksort  Memory: 4096kB
                          ->  Nested Loop  (cost=0.56..20461.65 rows=188509 width=8) (actual time=0.114..186.177 rows=155860 loops=2)
                                ->  Parallel Seq Scan on products p1_0  (cost=0.00..4206.59 rows=2514 width=8) (actual time=0.027..17.912 rows=2078 loops=2)
                                      Filter: (category_id = 36)
                                      Rows Removed by Filter: 97922
                                ->  Index Only Scan using idx_order_items_product_id_covering on order_items oi1_0  (cost=0.56..5.73 rows=74 width=16) (actual time=0.053..0.073 rows=75 loops=4155)
                                      Index Cond: (product_id = p1_0.id)
                                      Heap Fetches: 0
        ->  Index Scan using customers_pkey on customers c1_0  (cost=0.42..0.46 rows=1 width=88) (actual time=0.040..0.040 rows=1 loops=20)
              Index Cond: (id = o1_0.customer_id)
Planning Time: 2.258 ms
Execution Time: 244.490 ms
```

**해설**
- **Execution Time 1423~2299ms → 244.490ms, 약 6~9배 개선.** LOG009와 달리 이번엔
  노이즈가 아니라 플랜 구조 자체가 바뀌었다.
- **`Index Only Scan ... Heap Fetches: 0`**: 예상했던 대로, `order_id`가 인덱스
  안에 이미 있어서 힙 접근이 완전히 사라졌다. `loops=4155`(상품 개수만큼 반복)인데도
  `actual time=0.053..0.073`으로 개별 탐색이 사실상 공짜 수준.
- 힙 접근이 사라지자 옵티마이저가 챕터 9에서 거부했던 **인덱스 기반 Nested
  Loop**(products → order_items) 전략을 이번엔 선택했다. `Parallel Seq Scan on
  order_items`(1500만 건 전체 스캔)가 플랜에서 완전히 사라졌다.
- 이후 `order_id`로 정렬 → `orders`와 `Merge Semi Join`(`orders_pkey`를 역순으로
  읽어 `id DESC` 정렬을 공짜로 얻음) → `LIMIT 20`에서 조기 종료(`orders_pkey`가
  실제로는 308건만 읽고 멈춤, `customers`도 매치된 20건에 대해서만 인덱스 조회).
- **결론**: 커버링 인덱스는 "인덱스를 쓸지 말지"를 바꾼 게 아니라, **인덱스를 쓰는
  비용 자체(힙 접근)를 없애서 옵티마이저의 판단 기준을 바꿨다.** 챕터 9의 결론
  ("선택도 2%로는 단일 컬럼 인덱스로 못 고침")을 뒤집은 게 아니라, 애초에 그
  계산에 들어가던 "힙 접근 비용"이라는 전제를 제거한 것.

### 4. 정리 — 중복 인덱스 제거

`idx_order_items_product_id_covering`이 기존 `idx_order_items_product_id`(단순
`product_id` 인덱스)를 완전히 상위 호환한다(같은 검색을 지원하면서 `order_id`까지
포함) — 후자를 유지할 이유가 없어 `DROP`했다.

```sql
DROP INDEX idx_order_items_product_id;
```

## 시행착오 / Q&A

**Q. `INCLUDE (order_id)` 대신 그냥 `(product_id, order_id)` 복합 키로 만들면
안 되나?**
A. 될 수도 있지만 의미가 다르다. 복합 키(`product_id, order_id`)로 만들면
`order_id`도 정렬/검색 키의 일부가 되어 `WHERE product_id = ? AND order_id > ?`
같은 조건까지 지원할 수 있지만, 그만큼 B-tree 트리 구조 자체가 더 크고 복잡해진다.
`INCLUDE`는 정렬/검색엔 전혀 관여하지 않고 순수하게 "결과로 돌려줄 데이터"만
리프 페이지에 얹어두는 거라 더 가볍다. 이번처럼 `order_id`가 검색 조건이 아니라
단순히 "같이 필요한 값"일 땐 `INCLUDE`가 더 적합한 선택.

## 최종 구성

`order_items` 테이블 인덱스:

| 인덱스 | 컬럼 | 용도 |
|---|---|---|
| `order_items_pkey` | `id` | PK |
| `idx_order_items_product_id_covering` | `product_id` INCLUDE `order_id` | 상품 기준 조회 + 카테고리 필터용 EXISTS 서브쿼리, Index Only Scan 지원 |

`db/schema.sql`에 반영 완료.

## ADR

### Decision
- `order_items`에 필요했던 `product_id` 인덱스는 커버링 인덱스
  (`INCLUDE (order_id)`)로 만든다 — 단순 인덱스보다 저장 공간은 조금 더 들지만,
  이 프로젝트의 대표적인 "상품→주문 역참조" 쿼리 패턴(챕터 9의 카테고리 필터
  포함)에서 힙 접근을 완전히 없애줘서 이득이 명확하다.

### Drivers
- 챕터 9에서 인덱스를 걸어도 플랜이 안 바뀌었던 원인이 "선택도 부족"이 아니라
  "힙 접근 비용"이었을 가능성을 검증할 필요가 있었음

### Alternatives considered
- 복합 키 `(product_id, order_id)` — `order_id`가 검색 조건이 아니라 단순 결과값
  용도라 `INCLUDE`가 더 적합하다고 판단, 기각

### Consequences
- 기존 `idx_order_items_product_id`는 완전히 상위 호환되어 제거함 — 인덱스
  유지보수 부담(쓰기 성능 영향)이 줄었음
- 커버링 인덱스는 `INCLUDE` 컬럼이 늘어날수록 인덱스 크기와 쓰기 비용이 커진다 —
  "정말 자주 조회되는 값만" 담아야 한다는 원칙을 챕터 14(인덱스가 write 성능에
  미치는 영향)에서 더 다룰 예정
- Index Only Scan이 힙을 완전히 건너뛰려면 visibility map이 최신 상태여야 함
  (VACUUM 관련) — 챕터 15에서 다룰 주제로 남겨둠

### Follow-ups
- 챕터 11 — 대용량 페이지네이션: offset 한계, cursor 전환
