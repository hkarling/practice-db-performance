# LOG011 — 대용량 페이지네이션 (offset 한계 → cursor 전환)

## 배경 / 목표

Phase 3 챕터 11. `OFFSET` 기반 페이지네이션이 페이지가 깊어질수록 느려지는 걸
실측으로 확인하고, 커서(keyset) 기반 페이지네이션으로 전환했을 때 얼마나
개선되는지 확인한다.

## 개념

### `OFFSET`의 근본적인 한계
`OFFSET n LIMIT m`은 "n개를 건너뛰고 m개를 반환"하라는 뜻인데, DB는 이걸 **실제로
n개를 읽고 버린 다음에야** m개를 반환한다. 인덱스가 있어도 마찬가지다 — 인덱스를
이용해 순서대로 읽어나가되, 앞의 n개를 스캔하면서 그냥 버리는 것뿐이다. 그래서
`OFFSET`이 커질수록(페이지가 뒤로 갈수록) 비용이 **`O(offset + limit)`로 계속
증가**한다.

### 커서(Keyset) 페이지네이션
`OFFSET` 대신 "마지막으로 본 행의 키 값"을 조건으로 쓴다:

```sql
-- OFFSET 방식
SELECT * FROM orders ORDER BY id DESC OFFSET 4900000 LIMIT 20;

-- 커서 방식 (마지막으로 본 id가 100000이라면)
SELECT * FROM orders WHERE id < 100000 ORDER BY id DESC LIMIT 20;
```

커서 방식은 인덱스로 `id < 100000`인 지점으로 바로 점프해서 20개만 읽으면
끝난다 — 몇 페이지째인지와 무관하게 항상 `O(limit)`. 대신 "10페이지로 바로 이동"
같은 임의 페이지 점프는 못 하고 "다음 페이지"만 가능하다는 트레이드오프가 있다.

### 언제 어느 쪽을 쓰나
"무조건 커서가 낫다"가 아니다 — 대부분의 검색/목록 화면은 사용자가 1~3페이지
안에서 끝나는 경우가 많아 그 깊이에서는 `OFFSET`도 충분히 빠르다. 반면 무한
스크롤, API로 전체 데이터를 순회하는 배치/익스포트, 실제로 뒤 페이지까지 자주
파고드는 대시보드라면 커서가 확실히 낫다. 커서는 "전체 몇 페이지" 같은 표시도
어렵다(전체 개수를 알려면 결국 별도 카운트 쿼리 필요) — 화면 성격에 따라 나눠
쓰는 게 일반적이다.

## 진행 내용

### 1. `OFFSET` 얕은 페이지 vs 깊은 페이지

```sql
EXPLAIN ANALYZE
SELECT * FROM orders ORDER BY id DESC OFFSET 0 LIMIT 20;
```
```
Limit  (cost=0.43..1.16 rows=20 width=49) (actual time=0.088..0.092 rows=20 loops=1)
  ->  Index Scan Backward using orders_pkey on orders  (cost=0.43..181011.43 rows=5000000 width=49) (actual time=0.087..0.089 rows=20 loops=1)
Planning Time: 0.087 ms
Execution Time: 0.108 ms
```

```sql
EXPLAIN ANALYZE
SELECT * FROM orders ORDER BY id DESC OFFSET 4900000 LIMIT 20;
```
```
Limit  (cost=177391.21..177391.94 rows=20 width=49) (actual time=947.634..947.640 rows=20 loops=1)
  ->  Index Scan Backward using orders_pkey on orders  (cost=0.43..181011.43 rows=5000000 width=49) (actual time=0.023..793.757 rows=4900020 loops=1)
Planning Time: 0.073 ms
JIT:
  Functions: 2
  Options: Inlining false, Optimization false, Expressions true, Deforming true
  Timing: Generation 0.096 ms (Deform 0.000 ms), Inlining 0.000 ms, Optimization 0.135 ms, Emission 0.940 ms, Total 1.172 ms
Execution Time: 947.826 ms
```

**해설**
- **`0.108ms → 947.826ms`, 약 8,776배 차이.** 두 쿼리 모두 `Index Scan Backward
  using orders_pkey`로 **똑같이 인덱스를 쓰는데도** 이 차이가 났다.
- 깊은 페이지 쪽의 `actual rows=4900020`이 원인 — 인덱스를 타고 490만 20개를
  **실제로 다 읽고** 490만 건은 버린 뒤 마지막 20개만 반환했다. `cost=0.43..181011.43`은
  두 쿼리가 완전히 동일한데(둘 다 "테이블 전체를 훑을 수 있는" 잠재 비용), `Limit`
  노드가 어디서 멈추느냐만 다르다.
- **JIT은 깊은 페이지 쪽에만 등장**했다 — Postgres는 플랜의 예상 total cost가
  `jit_above_cost`(기본 100000)를 넘을 때만 JIT을 시도한다. 얕은 페이지는
  `cost=1.16`으로 한참 못 미쳐 JIT을 안 썼고, 깊은 페이지는 `cost=181011.43`으로
  넘어서 JIT이 작동했다(챕터 1에서 배운 원칙의 재확인). `Execution Time`은 JIT
  컴파일 시간까지 포함한 총 시간이다 — 여기선 컴파일에 `Total 1.172ms`를 썼지만
  전체(947.826ms) 중 실제 스캔 작업이 압도적으로 커서 무시할 수준.

### 2. 커서 방식으로 같은 위치 조회

```sql
EXPLAIN ANALYZE
SELECT * FROM orders WHERE id < 100000 ORDER BY id DESC LIMIT 20;
```
```
Limit  (cost=0.43..1.21 rows=20 width=49) (actual time=0.919..0.924 rows=20 loops=1)
  ->  Index Scan Backward using orders_pkey on orders  (cost=0.43..3767.17 rows=97185 width=49) (actual time=0.917..0.921 rows=20 loops=1)
        Index Cond: (id < 100000)
Planning Time: 0.127 ms
Execution Time: 0.943 ms
```

**해설**
- **947.826ms → 0.943ms, 약 1,005배 개선.** `OFFSET 0`(0.108ms)과 거의 같은
  자릿수로 돌아왔다.
- **`Index Cond: (id < 100000)`**: `OFFSET` 버전엔 없던 조건이다. B-tree에서
  `id=100000` 지점으로 바로 점프해서 역순으로 20개만 읽고 멈춘다 — 앞에서부터
  하나씩 세면서 버리는 과정 자체가 없다.
- `Index Scan Backward` 노드의 `actual rows=20`(아까는 4900020) — 딱 필요한
  20건만 실제로 만졌다는 뜻.

| 방식 | Execution Time | Index Scan Backward `actual rows` |
|---|---|---|
| `OFFSET 0` (1페이지) | 0.108 ms | 20 |
| `OFFSET 4900000` (깊은 페이지) | 947.826 ms | 4,900,020 |
| 커서(`WHERE id < 100000`) | 0.943 ms | 20 |

### 3. 리포지토리에 커서 기반 조회 구현

```java
public interface OrderQueryRepository {
  List<Order> findNextPage(Long cursorId, int size);
}
```

```java
@Override
public List<Order> findNextPage(Long cursorId, int size) {
  return queryFactory
      .selectFrom(order)
      .join(order.customer, customer).fetchJoin()
      .where(cursorId != null ? order.id.lt(cursorId) : null)
      .orderBy(order.id.desc())
      .limit(size)
      .fetch();
}
```

`cursorId`가 `null`이면(첫 페이지) 조건 없이 최신순 상위 `size`건, 있으면(다음
페이지) `id < cursorId`로 이어서 조회한다. `Pageable`의 offset 개념 자체가 없다 —
"어디부터 이어갈지"만 있다.

### 4. 검증 — 연속성 확인

```java
List<Order> firstPage = orderRepository.findNextPage(null, 20);
Long lastIdOfFirstPage = firstPage.get(firstPage.size() - 1).getId();

List<Order> secondPage = orderRepository.findNextPage(lastIdOfFirstPage, 20);
Long firstIdOfSecondPage = secondPage.get(0).getId();
```

결과: 1페이지 마지막 id=`4999981`, 2페이지 첫 id=`4999980` — 정확히 연속(차이
1). 중복도 누락도 없이 이어졌다.

## 시행착오 / Q&A

**Q. 커서 쿼리도 `cost=0.43..3767.17`이라 완전히 공짜는 아니지 않나?**
A. 이 cost는 "`id < 100000`에 매치되는 전체(약 97185건)를 다 읽는다면"의 추정치다.
`LIMIT 20` 덕분에 실제로는 그 근처도 안 가고 20건에서 멈췄다(`actual
rows=20`). 챕터 3~4에서 봤던 "`LIMIT`이 있으면 인덱스 스캔이 조기 종료된다"는
원리가 여기서도 동일하게 적용된다.

## 최종 구성

| 파일 | 변경 |
|---|---|
| `src/main/java/.../infra/OrderQueryRepository.java` | `findNextPage` 메서드 추가 |
| `src/main/java/.../infra/OrderQueryRepositoryImpl.java` | 구현 |
| `src/test/java/.../infra/CursorPaginationTest.java` | 신규 |

## ADR

### Decision
- 깊은 페이지 접근이 실제로 필요한 화면(무한 스크롤, 배치/익스포트 등)에는 커서
  기반 페이지네이션(`findNextPage`)을 쓰고, 얕은 몇 페이지 안에서 끝나는
  일반적인 검색 화면은 기존 `Pageable`/`OFFSET` 방식(`search`, `findAllWithCustomer`
  등)을 그대로 유지한다 — 상황에 따라 나눠 쓰는 쪽으로 결정.

### Drivers
- `OFFSET`이 페이지 깊이에 비례해 느려진다는 걸 실측(8,776배 차이)으로 확인했고,
  커서로 전환 시 페이지 깊이와 무관하게 항상 빠르다는 것(1,005배 개선)도 확인함

### Alternatives considered
- 모든 페이지네이션을 커서로 통일 — "임의 페이지 이동", "전체 개수 표시"가
  필요한 화면(관리자 검색 등)엔 커서가 안 맞아 기각. 화면 성격별로 나눠 쓰기로 함

### Consequences
- 커서 기반 API는 클라이언트가 "마지막으로 본 id"를 유지해야 한다 — REST API
  설계 시 응답에 `nextCursor` 같은 필드를 포함하는 관례가 필요(이번 챕터에서는
  리포지토리 레벨까지만 구현, API 설계는 범위 밖)
- 정렬 기준이 유일성을 보장하지 않으면(예: `ordered_at`만으로 정렬 시 동시각
  주문이 여러 건) 커서가 일부 행을 건너뛰거나 중복 반환할 수 있음 — `id`처럼
  유일한 컬럼을 커서 키로 쓰거나, 동점 처리를 위한 보조 키(예: `(ordered_at, id)`
  복합 커서)가 필요하다는 점을 유의해야 함(이번 실습은 `id` 단일 키라 해당 없음)

### Follow-ups
- 챕터 12 — 집계 쿼리 최적화
