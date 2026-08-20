# LOG006 — fetch join으로 N+1 해결

## 배경 / 목표

Phase 2 챕터 6. LOG005에서 재현한 N+1(22번의 SELECT)을 JPQL fetch join으로 1번의
쿼리로 줄이고, 실제 쿼리 횟수와 실행 시간을 비교한다.

## 개념

### Fetch Join
JPQL에서 `JOIN FETCH`를 쓰면 연관 엔티티를 별도 쿼리가 아니라 원래 쿼리의 SQL
`JOIN`으로 한 번에 가져온다.

```jpql
SELECT o FROM Order o JOIN FETCH o.customer
```

- 일반 `JOIN`(FETCH 없이)은 필터링/조인 조건으로만 쓰이고 `customer` 필드는 여전히
  LAZY 프록시로 남는다 — 나중에 접근하면 또 N+1이 터진다. `FETCH` 키워드가 붙어야
  "이 연관관계를 SELECT 절에도 포함시켜서 즉시 채워라"는 뜻이 된다.
- 결과 SQL은 `orders`와 `customers`를 `JOIN`한 단일 쿼리가 된다.

### 페이지네이션과 fetch join을 같이 쓸 때의 안전 기준: to-one vs to-many
`Order.customer`는 `@ManyToOne`(to-one, 다대일)이다. fetch join + `LIMIT`을 같이 쓰면
보통 "컬렉션(`@OneToMany`) fetch join + 페이지네이션은 위험하다"는 이야기를 듣는데,
그건 **to-many** 관계에 한정된 문제다 — JOIN 결과가 부모 1행당 여러 행으로 늘어나서
(cartesian product) DB의 `LIMIT`이 부모 기준이 아니라 조인된 행 기준으로 잘려버린다.
`customer`는 to-one이라 조인해도 행 수가 안 늘어나서(주문 1건당 고객 정확히 1명)
안전하다. to-many fetch join + 페이지네이션 조합은 이후 챕터(컬렉션 fetch join을
다루게 되면)에서 별도로 검증이 필요하다.

## 진행 내용

### 1. Fetch join 쿼리 메서드 추가

```java
public interface OrderRepository extends JpaRepository<Order, Long> {

  @Query("SELECT o FROM Order o JOIN FETCH o.customer ORDER BY o.id DESC")
  List<Order> findAllWithCustomer(Pageable pageable);
}
```

반환 타입을 `Page<Order>`가 아니라 `List<Order>`로 뒀다 — fetch join 쿼리에
`Pageable`을 쓸 때 `Page`(전체 개수 카운트 쿼리 포함)를 요구하면 카운트 쿼리와
fetch join을 함께 만드는 게 애매해지므로, 단순하게 `List` + `Pageable`(LIMIT 용도만)로
갔다.

### 2. 재현 테스트 (`FetchJoinTest`)

```java
@Slf4j
@SpringBootTest
@Transactional
class FetchJoinTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("fetch join으로 조회하면 customer 접근 시 추가 쿼리가 나가지 않는다")
  void findAllWithCustomer_thenAccessCustomer_noAdditionalQueries() {
    List<Order> orders = orderRepository.findAllWithCustomer(PageRequest.of(0, 10));

    for (Order order : orders) {
      assertThat(order.getCustomer().getName()).isNotBlank();
    }
  }
}
```

### 3. 결과 — SQL 로그

```
select
    o1_0.id,
    o1_0.created_at,
    o1_0.customer_id,
    c1_0.id,
    c1_0.city,
    c1_0.created_at,
    c1_0.email,
    c1_0.name,
    c1_0.state,
    c1_0.updated_at,
    c1_0.zip_code,
    o1_0.ordered_at,
    o1_0.status,
    o1_0.updated_at
from
    orders o1_0
join
    customers c1_0
        on c1_0.id=o1_0.customer_id
order by
    o1_0.id desc
fetch
    first ? rows only
```

이 **1개 쿼리 이후, 10건의 customer 접근에서 추가 `SELECT`가 전혀 나가지 않았다**
(로그에 `---------- 2-1. ---------- ~ 2-10. ----------` 마커만 연속으로 찍히고 그
사이에 `select`가 없음). `Page` 대신 `List`를 쓴 덕분에 챕터 5에서 봤던
`SELECT count(*) FROM orders` 쿼리도 안 나갔다.

**총 쿼리 수: 22번 → 1번.**

### 4. 실행 시간 비교 — 예상과 다른 결과

| | 쿼리 수 | 실행 시간 |
|---|---|---|
| N+1 (`NPlusOneTest`, LOG005) | 22 | 0.769s |
| fetch join (`FetchJoinTest`) | 1 | 0.705s |

**해설**: 쿼리 수는 22배 차이가 났지만, 실행 시간은 거의 차이가 없다(약 8% 차이 —
오차 범위에 가까움). 로컬호스트에서 도는 로컬 Postgres라 쿼리 하나당 네트워크
왕복(round trip) 비용이 워낙 작아서(밀리초 미만), 추가 쿼리 21번의 누적 비용이 전체
실행 시간에서 티가 안 났다. 챕터 4에서 봤던 "작은 스케일/짧은 지연 환경에서는 구조적
차이가 실측 시간에 드러나지 않는다"는 패턴이 여기서도 반복됐다.

**그렇다고 N+1이 문제없다는 뜻은 아니다** — fetch join의 진짜 이득은 "쿼리 하나당
드는 시간"이 아니라 **"왕복 횟수 자체를 줄이는 것"**이다:
- 네트워크 지연이 실제로 있는 환경(원격 DB, 클라우드 등)에서는 왕복 1번의 비용이
  로컬호스트보다 훨씬 크므로, 21번의 추가 왕복이 훨씬 크게 체감된다.
- 동시 요청이 많은 운영 환경에서는 쿼리 수가 22배라는 건 DB 커넥션 풀/DB 자체에 걸리는
  부하도 22배에 가깝다는 뜻이다.
- 이번 실험처럼 "실측 시간 차이가 작다"고 해서 N+1을 방치해도 된다는 결론으로 이어지면
  안 된다 — **쿼리 수 자체가 신뢰할 수 있는 지표**이고, 환경(네트워크 지연, 동시성)에
  따라 체감 크기만 달라질 뿐이다.

## 시행착오 / Q&A

**Q. `Page<Order>` 반환 타입에 fetch join 쿼리를 그대로 쓰면 안 되나?**
A. 될 수도 있지만(Spring Data JPA가 별도 카운트 쿼리를 자동 생성해줌), 이번엔
단순하게 `List` + `Pageable`(LIMIT 용도)로 갔다. `Page`가 필요하면(전체 개수 표시가
꼭 필요한 화면이라면) 카운트 쿼리를 `@Query(countQuery = "...")`로 명시적으로 분리해
지정하는 방법도 있다 — 지금 단계에선 다루지 않음.

## 최종 구성

| 파일 | 변경 |
|---|---|
| `src/main/java/io/hkarling/practice/infra/OrderRepository.java` | `findAllWithCustomer` fetch join 쿼리 메서드 추가 |
| `src/test/java/io/hkarling/practice/infra/FetchJoinTest.java` | 신규 |

## ADR

### Decision
- N+1 해결에는 JPQL `JOIN FETCH`를 사용한다. to-one 연관관계(`@ManyToOne`,
  `@OneToOne`)에는 페이지네이션과 함께 써도 안전하지만, to-many 연관관계(`@OneToMany`)
  fetch join + 페이지네이션은 별도 검증이 필요하다(이후 챕터에서 다룰 수 있음).

### Drivers
- LOG005에서 재현한 N+1(22번 쿼리)을 실제로 줄여보고, "쿼리 수"와 "실행 시간"이 항상
  비례하지는 않는다는 걸 직접 확인할 필요가 있었음

### Alternatives considered
- `@EntityGraph` — JPQL 없이 애노테이션만으로 fetch join과 동일한 효과를 낼 수 있는
  대안. 이번엔 JPQL로 명시적으로 작성해 동작 원리를 더 분명히 보는 쪽을 택함. 추후
  QueryDSL(챕터 8)에서 같은 쿼리를 다른 방식으로 작성해볼 때 비교 대상으로 남겨둠

### Consequences
- 쿼리 수 감소가 실행 시간 감소로 항상 즉시 드러나는 건 아니다(이번 로컬 환경처럼
  네트워크 지연이 거의 없으면 특히) — 성능 판단은 "쿼리 수"라는 구조적 지표와 "실측
  시간"이라는 환경 의존적 지표를 함께 봐야 한다는 교훈을 챕터 4에 이어 재확인

### Follow-ups
- 챕터 7: batch size 설정과 fetch join의 트레이드오프
