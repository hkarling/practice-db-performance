# LOG009 — 다중 조건 필터링 (상태 + 기간 + 카테고리)

## 배경 / 목표

Phase 3 챕터 9. 상태(status) + 기간(ordered_at 범위) + 카테고리 3가지를 **전부
선택적(optional)으로** 조합해 주문을 검색하는 기능을 QueryDSL 동적 쿼리로 구현하고,
그 과정에서 실제로 겪은 JOIN fan-out(중복 행) 버그를 재현 → 원인 분석 → 수정까지
진행한다.

## 개념

### QueryDSL 동적 조건 조합 — null-safe `BooleanExpression`
조건이 optional이면 고정된 JPQL `@Query` 하나로는 대응이 안 된다. QueryDSL은 각
조건을 **null을 반환할 수 있는 `BooleanExpression` 메서드**로 쪼개서 조립한다:

```java
private BooleanExpression statusEq(OrderStatus status) {
  return status != null ? order.status.eq(status) : null;
}
```

`.where(a, b, c)`처럼 여러 `Predicate`를 넘기면 QueryDSL이 `null`인 것들은 자동으로
무시하고 나머지만 `AND`로 묶는다 — 이게 동적 쿼리 조합의 핵심 트릭.

### 매핑 안 된 연관관계로 조인하기
`Order`엔 `orderItems` 컬렉션이 매핑돼 있지 않다(`OrderItem`→`Order`만
`@ManyToOne`). QueryDSL에서는 이런 경우에도 조인 조건을 직접 명시하면 된다:

```java
.join(orderItem).on(orderItem.order.eq(order))
```

### JOIN fan-out — to-many 조인의 근본적인 위험
`orders → order_items → products → categories`처럼 **한 부모(Order)가 여러
자식(OrderItem)을 가질 수 있는 경로**를 필터링 목적으로 조인하면, 부모 1건이 자식
개수만큼 여러 행으로 늘어난다(카테시안 곱). 챕터 6에서 "to-many + 페이지네이션은
위험하다"고 언급했던 문제의 실제 사례.

## 진행 내용

### 1. `OrderSearchCondition` (검색 조건 DTO)

```java
public record OrderSearchCondition(
    OrderStatus status,
    OffsetDateTime from,
    OffsetDateTime to,
    Long categoryId
) {
}
```

### 2. 첫 번째 시도 — "순진한" 구현 (fan-out 재현용)

카테고리 필터가 필요할 수도 있으니 `order_items`/`products`/`categories`를 항상
조인해두는, 흔히 저지르는 방식으로 먼저 작성했다:

```java
queryFactory
    .selectFrom(order)
    .join(order.customer, customer).fetchJoin()
    .join(orderItem).on(orderItem.order.eq(order))
    .join(orderItem.product, product)
    .join(product.category, category)
    .where(statusEq(...), orderedAtBetween(...), categoryIdEq(categoryId))
    .orderBy(order.id.desc())
    .offset(pageable.getOffset())
    .limit(pageable.getPageSize())
    .fetch();
```

### 3. 버그 재현 — 세 단계로 실증

**(1) 무작위 페이지에서는 중복이 안 보였다.** `categoryId=36`("Rugs", 상품
4155개)만으로 `LIMIT 20` 조회 → 20건 전부 distinct. 운이 좋았을 뿐이라고 판단해,
실제로 카테고리 36 상품을 2개 이상 담은 주문을 SQL로 직접 찾았다(`order_id=23`).

**(2) `order_id=23`을 직접 겨냥해 검증** — `WHERE o.id=23 AND category.id=36`으로
좁혀서 원시 SQL을 psql로 직접 실행:
```
 id
----
 23
 23
(2 rows)
```
원시 SQL은 분명 2행을 반환했다. 그런데 같은 조건을 QueryDSL(`fetchJoin` 없이 필터
조인만 사용)로 조회하면 `List<Order>` 크기가 **1**로 나왔다 — Hibernate가 엔티티
루트만 셀렉트하는 쿼리에서는, 같은 PK를 가진 행을 자동으로 하나의 리스트 항목으로
합쳐준다(명시적 `distinct()` 없이도). **이게 "버그가 없다"는 뜻은 아니다** — 진짜
문제는 다음 단계에서 드러난다.

**(3) 진짜 문제 — `LIMIT`이 원시 행 개수 기준으로 잘린다.** Hibernate가 Java
리스트에서 중복을 합쳐줘도, Postgres의 `LIMIT`/`OFFSET`은 SQL 결과의 **원시 행**
개수를 기준으로 자른다. `id DESC` 정렬에서 카테고리 36 매치 중 첫 중복
(`order_id=4999288`)이 43번째 원시 행에서 나온다는 걸 SQL로 찾아, `OFFSET 25 LIMIT
20`(26~45번째 원시 행 구간, 이 중복을 포함) 구간을 확인:
```
raw_rows | distinct_orders
---------+-----------------
      20 |              19
```
**`LIMIT 20`을 요청했는데 실제 distinct 주문은 19건.** 20번째로 와야 할 주문이
이 페이지에서 통째로 누락됐다 — Hibernate의 자동 중복 제거는 "리스트에 같은 객체가
안 보이게" 해줄 뿐, "요청한 페이지 크기만큼 채워준다"는 보장은 전혀 안 해준다.

### 4. 수정 — `.distinct()` vs `EXISTS`

**`.distinct()`**: `SELECT DISTINCT`는 `LIMIT`/`OFFSET`보다 먼저 적용되므로, 중복
행이 잘리기 전에 하나로 합쳐진다. 같은 `OFFSET 25 LIMIT 20` 구간을 `.distinct()`
버전으로 재확인하면 20건 전부 distinct로 나온다(정상화 확인).

**`EXISTS` 서브쿼리**: 카테고리 조건은 "이 주문에 해당 카테고리 상품이 하나라도
있는가"라는 존재 여부만 필요하지, 실제로 `order_items`/`products` 데이터를 가져올
필요는 없다. 애초에 조인을 안 해서 중복 행 자체가 안 생기는 더 근본적인 방식:

```java
private BooleanExpression categoryExists(Long categoryId) {
  if (categoryId == null) {
    return null;
  }
  QOrderItem oi = new QOrderItem("oi");
  return JPAExpressions.selectOne()
      .from(oi)
      .join(oi.product, product)
      .where(oi.order.eq(order), product.category.id.eq(categoryId))
      .exists();
}
```

`QOrderItem.orderItem`(컴파일 타임에 생성되는 싱글턴 인스턴스, 항상 같은 SQL
별칭을 씀) 대신 `new QOrderItem("oi")`로 새 인스턴스를 만든 이유: **서브쿼리 안에서
참조하는 엔티티는 바깥 쿼리와 다른 별칭을 가져야 한다.** 바깥 쿼리와 서브쿼리가 같은
싱글턴 인스턴스를 쓰면 둘 다 SQL에서 같은 테이블 별칭을 갖게 돼 충돌한다 — 순수
SQL로 치면 `WHERE EXISTS (SELECT 1 FROM order_items oi WHERE ...)`의 안쪽 `oi`와
바깥 쿼리의 `oi`가 같은 이름인 것과 같은 문제. QueryDSL에서 서브쿼리를 작성할 때는
그 안에서 쓰는 엔티티를 항상 새 인스턴스로 명시적 별칭을 줘서 격리하는 게 표준
관례다(바깥 쿼리가 나중에 같은 엔티티를 조인하게 되더라도 안전하도록 방어적으로
짜는 것).

**최종적으로 `search()`는 `EXISTS` 버전으로 확정했다** — `.distinct()`는 엔티티의
모든 컬럼 기준으로 `Unique`/정렬을 수행해야 해서 엔티티가 커질수록 비용이 늘어나는
구조적 단점이 있는 반면, `EXISTS`는 그런 전체 컬럼 정렬이 필요 없다.

### 실제 생성된 SQL 비교

**`.distinct()` 버전** — `order_items`/`products`/`categories`를 전부 바깥 쿼리의
`FROM`/`JOIN`에 직접 끌어들인다:

```sql
select distinct
    o1_0.id, o1_0.created_at, o1_0.customer_id,
    o1_0.ordered_at, o1_0.status, o1_0.updated_at
from
    orders o1_0
join
    order_items oi1_0 on oi1_0.order_id=o1_0.id
join
    products p1_0 on p1_0.id=oi1_0.product_id
join
    categories c1_0 on c1_0.id=p1_0.category_id
where
    c1_0.id=?
order by
    o1_0.id desc
offset ? rows fetch first ? rows only
```

**`EXISTS` 버전** — 바깥 쿼리는 `orders`/`customers` 2개 테이블만 조인하고,
`order_items`/`products`는 서브쿼리 안에만 존재한다:

```sql
select
    o1_0.id, o1_0.created_at, o1_0.customer_id,
    c1_0.id, c1_0.city, c1_0.created_at, c1_0.email,
    c1_0.name, c1_0.state, c1_0.updated_at, c1_0.zip_code,
    o1_0.ordered_at, o1_0.status, o1_0.updated_at
from
    orders o1_0
join
    customers c1_0 on c1_0.id=o1_0.customer_id
where
    exists (
        select 1 from order_items oi1_0
        join products p1_0 on p1_0.id=oi1_0.product_id
        where oi1_0.order_id=o1_0.id and p1_0.category_id=36
    )
order by
    o1_0.id desc
offset 0 rows fetch first 20 rows only
```

두 가지 구조적 차이가 눈에 띈다:
1. **조인 개수**: `.distinct()`는 바깥 쿼리에 4개 테이블을 다 조인, `EXISTS`는
   바깥 쿼리 2개(orders/customers) + 서브쿼리 안 2개(order_items/products) — 바깥
   결과 집합 자체는 절대 뻥튀기되지 않는다.
2. **`categories` 테이블 자체를 안 건드림**: `.distinct()` 버전은 Java 코드에서
   `.join(product.category, category)`로 **명시적으로 조인**해서 `category.id`를
   필터링했기 때문에 실제 `categories` 테이블까지 접근한다(`c1_0.id=?`). 반면
   `categoryExists()`는 `product.category.id.eq(categoryId)`만 쓰고 별도로
   `.join(product.category, ...)`을 호출하지 않았다 — Hibernate는 "연관관계의 ID만
   비교하는" 경우 실제 조인 없이 FK 컬럼(`products.category_id`)을 바로 비교하는
   걸로 최적화해준다. 그래서 EXISTS 서브쿼리의 SQL엔 `categories` 테이블이 아예
   등장하지 않고 `p1_0.category_id=36`으로 끝난다. **연관관계의 ID만 필요할 땐
   명시적 `.join()`을 하지 않는 게 불필요한 조인을 하나 줄이는 방법**이라는 것도
   이번에 확인한 부수적인 교훈.

### 5. 성능 비교 — 인덱스로도 못 고친 부분

`.distinct()`와 `EXISTS` 두 버전을 `EXPLAIN ANALYZE`로 비교:

| | Execution Time |
|---|---|
| `.distinct()` | 1821.907 ms |
| `EXISTS` | 2299.501 ms (더 느림) |

**`.distinct()` 버전 플랜**:

```
Limit  (cost=268281.64..268294.76 rows=20 width=49) (actual time=1805.858..1811.941 rows=20 loops=1)
  ->  Unique  (cost=268265.23..478587.03 rows=320482 width=49) (actual time=1780.197..1786.295 rows=45 loops=1)
        ->  Incremental Sort  (cost=268265.23..473779.80 rows=320482 width=49) (actual time=1780.195..1786.273 rows=46 loops=1)
              Sort Key: o1_0.id DESC, o1_0.created_at, o1_0.customer_id, o1_0.ordered_at, o1_0.status, o1_0.updated_at
              Presorted Key: o1_0.id
              Full-sort Groups: 2  Sort Method: quicksort  Average Memory: 27kB  Peak Memory: 27kB
              ->  Nested Loop  (cost=268264.63..459358.11 rows=320482 width=49) (actual time=1779.950..1786.229 rows=65 loops=1)
                    ->  Nested Loop  (cost=268264.63..455350.46 rows=320482 width=57) (actual time=1779.841..1786.084 rows=65 loops=1)
                          ->  Gather Merge  (cost=268264.19..305589.60 rows=320482 width=16) (actual time=1779.757..1785.617 rows=65 loops=1)
                                Workers Planned: 2
                                Workers Launched: 2
                                ->  Sort  (cost=267264.17..267598.00 rows=133534 width=16) (actual time=1724.834..1724.926 rows=1104 loops=3)
                                      Sort Key: oi1_0.order_id DESC
                                      Sort Method: external merge  Disk: 2488kB
                                      Worker 0:  Sort Method: external merge  Disk: 2968kB
                                      Worker 1:  Sort Method: external merge  Disk: 2504kB
                                      ->  Parallel Hash Join  (cost=4238.01..253610.35 rows=133534 width=16) (actual time=13.007..1668.705 rows=103906 loops=3)
                                            Hash Cond: (oi1_0.product_id = p1_0.id)
                                            ->  Parallel Seq Scan on order_items oi1_0  (cost=0.00..232965.38 rows=6250138 width=16) (actual time=0.124..802.203 rows=4999854 loops=3)
                                            ->  Parallel Hash  (cost=4206.59..4206.59 rows=2514 width=16) (actual time=6.575..6.576 rows=1385 loops=3)
                                                  Buckets: 8192  Batches: 1  Memory Usage: 288kB
                                                  ->  Parallel Seq Scan on products p1_0  (cost=0.00..4206.59 rows=2514 width=16) (actual time=0.043..18.230 rows=4155 loops=1)
                                                        Filter: (category_id = 36)
                                                        Rows Removed by Filter: 195845
                          ->  Index Scan using orders_pkey on orders o1_0  (cost=0.43..0.47 rows=1 width=49) (actual time=0.006..0.006 rows=1 loops=65)
                                Index Cond: (id = oi1_0.order_id)
                    ->  Materialize  (cost=0.00..1.63 rows=1 width=8) (actual time=0.002..0.002 rows=1 loops=65)
                          ->  Seq Scan on categories c1_0  (cost=0.00..1.62 rows=1 width=8) (actual time=0.102..0.104 rows=1 loops=1)
                                Filter: (id = 36)
                                Rows Removed by Filter: 49
Planning Time: 5.542 ms
Execution Time: 1821.907 ms
```

**`EXISTS` 버전 플랜**:

```
Limit  (cost=267810.36..267834.15 rows=20 width=137) (actual time=2289.934..2296.293 rows=20 loops=1)
  ->  Nested Loop  (cost=267810.36..649016.83 rows=320482 width=137) (actual time=2267.760..2274.114 rows=20 loops=1)
        ->  Merge Semi Join  (cost=267809.93..502644.75 rows=320482 width=49) (actual time=2267.653..2273.185 rows=20 loops=1)
              Merge Cond: (o1_0.id = oi1_0.order_id)
              ->  Index Scan Backward using orders_pkey on orders o1_0  (cost=0.43..181011.43 rows=5000000 width=49) (actual time=0.032..0.117 rows=308 loops=1)
              ->  Gather Merge  (cost=267805.69..305131.10 rows=320482 width=8) (actual time=2267.556..2272.984 rows=20 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    ->  Sort  (cost=266805.67..267139.50 rows=133534 width=8) (actual time=2217.375..2217.456 rows=1367 loops=3)
                          Sort Key: oi1_0.order_id DESC
                          Sort Method: quicksort  Memory: 3073kB
                          Worker 0:  Sort Method: quicksort  Memory: 3073kB
                          Worker 1:  Sort Method: quicksort  Memory: 3073kB
                          ->  Parallel Hash Join  (cost=4238.01..253610.35 rows=133534 width=8) (actual time=18.072..2199.720 rows=103906 loops=3)
                                Hash Cond: (oi1_0.product_id = p1_0.id)
                                ->  Parallel Seq Scan on order_items oi1_0  (cost=0.00..232965.38 rows=6250138 width=16) (actual time=1.326..1253.388 rows=4999854 loops=3)
                                ->  Parallel Hash  (cost=4206.59..4206.59 rows=2514 width=8) (actual time=12.219..12.220 rows=1385 loops=3)
                                      Buckets: 8192  Batches: 1  Memory Usage: 256kB
                                      ->  Parallel Seq Scan on products p1_0  (cost=0.00..4206.59 rows=2514 width=8) (actual time=0.100..35.239 rows=4155 loops=1)
                                            Filter: (category_id = 36)
                                            Rows Removed by Filter: 195845
        ->  Index Scan using customers_pkey on customers c1_0  (cost=0.42..0.46 rows=1 width=88) (actual time=0.044..0.044 rows=1 loops=20)
              Index Cond: (id = o1_0.customer_id)
Planning Time: 2.300 ms
Execution Time: 2299.501 ms
```

두 플랜 모두 바닥에 `Parallel Seq Scan on order_items`(1500만 건 전체 스캔)가
있었다 — `order_items.product_id`에 인덱스가 없어서, 카테고리 36 상품(4155개)에
매치되는 `order_items`를 찾을 방법이 전체 스캔+해시 조인뿐이었다.

**`idx_order_items_product_id` 인덱스를 추가했지만, 플랜이 전혀 안 바뀌었다** —
여전히 `Parallel Seq Scan on order_items`. 카테고리 36의 매치 비율(31만 건 /
1500만 건 = 약 2%)이, "상품 4155개 각각에 대해 인덱스 탐색"보다 "전체를 한 번
순차 스캔하며 해시 매칭"이 더 싸다고 옵티마이저가 판단할 만큼은 낮지 않았다 —
**챕터 3에서 `status`(70%) 인덱스가 무시됐던 것과 원리가 같다.** 다만 이 인덱스
자체가 쓸모없는 건 아니다 — `WHERE product_id = 특정값`처럼 상품 하나의 판매
이력을 찾는 훨씬 선택도 높은 쿼리엔 유용해서, `db/schema.sql`에 유지하기로 했다.

인덱스 추가 후 실행 시간이 `.distinct()`는 거의 그대로(1921ms), `EXISTS`는 꽤
빨라졌지만(1423ms) 플랜 구조 자체는 안 바뀌었으므로, 이 시간 변화는 인덱스 효과가
아니라 버퍼 캐시 상태 등 노이즈로 보는 게 맞다(챕터 4에서 세운 "플랜이 안 바뀌면
실측 시간 변동은 노이즈" 원칙과 동일).

**결론**: 이 쿼리(카테고리 필터로 1500만 건짜리 `order_items`의 2%를 걸러내는
구조)는 단일 컬럼 인덱스로는 근본적으로 개선이 안 된다. 이건 챕터 10(커버링
인덱스)에서 다시 다룰 문제로 남겨둔다.

## 시행착오 / Q&A

**Q. `.distinct()`도 안 썼는데 왜 Java 리스트에서 중복이 자동으로 없어졌나?**
A. Hibernate는 쿼리의 SELECT 절이 순수하게 엔티티 자체(여기선 `Order` + fetch join된
`Customer`)만 대상일 때, 같은 PK를 가진 원시 행들을 하나의 엔티티 인스턴스로
식별해 결과 리스트에 중복으로 담지 않는다. 다만 이건 "화면에 중복 카드가 안
보인다" 수준의 안전장치일 뿐, `LIMIT`이 원시 행 기준으로 잘리는 문제 자체는
전혀 막아주지 못한다 — 페이지네이션에서 실제 주문이 누락되는 훨씬 심각한 버그로
이어질 수 있다.

**Q. `EXISTS`가 이론적으로 더 빨라야 하는데 왜 `.distinct()`보다 느렸나?**
A. `order_items.order_id`에도 인덱스가 없어서, "이 주문 하나에 대해 EXISTS 체크"를
인덱스로 빠르게 할 방법이 없었다. 그래서 옵티마이저는 (합리적으로) `EXISTS`도
결국 "카테고리 36에 매치되는 order_items를 전부 찾아서 orders와 병합
(`Merge Semi Join`)"하는, `.distinct()`와 거의 같은 전략으로 재작성했고, 여기에
병합을 위한 추가 정렬 비용까지 얹혀서 오히려 더 느려졌다.

## 최종 구성

| 파일 | 변경 |
|---|---|
| `src/main/java/.../infra/OrderSearchCondition.java` | 신규 — 검색 조건 record |
| `src/main/java/.../infra/OrderQueryRepository.java` | `search()` 메서드 추가 |
| `src/main/java/.../infra/OrderQueryRepositoryImpl.java` | `search()` 구현(EXISTS 방식으로 확정) |
| `src/test/java/.../infra/OrderSearchFanOutTest.java` | 신규 — fan-out 재현/검증 테스트 3개 |
| `db/schema.sql` | `idx_order_items_product_id` 추가 |

## ADR

### Decision
- 다중 조건 검색에서 to-many 관계(컬렉션)를 필터링 목적으로 조인할 때는 `JOIN` +
  `.distinct()`가 아니라 **`EXISTS` 서브쿼리**를 기본 패턴으로 삼는다 — 애초에
  중복 행이 생기지 않고, 엔티티가 커져도 정렬 비용이 늘지 않는다.

### Drivers
- fan-out으로 인한 페이지네이션 누락 버그를 직접 겪고 원인을 규명할 필요가 있었음
  (Hibernate의 자동 리스트 중복 제거가 문제를 가려서 더 위험함을 확인)

### Alternatives considered
- `.distinct()` — 정합성은 고치지만 엔티티 전체 컬럼 기준 정렬이 필요해 구조적으로
  더 무거움. 정합성만 급하게 고쳐야 하는 상황의 임시방편으로는 유효
- `idx_order_items_product_id` 인덱스로 해결 — 카테고리 필터의 선택도(2%)가
  인덱스 탐색 비용을 정당화하기엔 부족해 기각. 다만 다른(더 선택도 높은) 쿼리를
  위해 인덱스 자체는 유지

### Consequences
- 이 검색 쿼리(카테고리 조건 포함 시)는 여전히 1.4~2초대로 느리다 — 단일 컬럼
  인덱스로는 한계가 있음을 확인한 것이 이번 챕터의 실질적 결론
- Hibernate의 "엔티티 루트 자동 중복 제거"는 신뢰하면 안 된다 — 항상 `LIMIT`이
  걸린 to-many 조인에서는 명시적으로 fan-out 여부를 검증해야 함

### Follow-ups
- 챕터 10 — 커버링 인덱스: 이번에 못 푼 "카테고리 필터 성능" 문제를 다른 접근으로
  재검토
