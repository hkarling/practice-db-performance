# LOG008 — QueryDSL로 동일 쿼리 작성

## 배경 / 목표

Phase 2 챕터 8. LOG006에서 JPQL `@Query`로 작성한 fetch join 쿼리
(`findAllWithCustomer`)를 QueryDSL로 동일하게 다시 작성해서, 생성되는 SQL과 쿼리
횟수가 같은지 확인한다.

## 개념

### QueryDSL이란
JPQL을 문자열이 아니라 **Java 코드로** 작성하게 해주는 라이브러리. 엔티티마다
어노테이션 프로세서(`querydsl-apt`)가 컴파일 타임에 `Q{엔티티명}` 클래스(예: `QOrder`,
`QCustomer`)를 자동 생성하고, 그걸로 쿼리를 조립한다.

- **JPQL `@Query`**(챕터 6): 문자열이라 필드명 오타/변경을 컴파일 타임에 못 잡는다 —
  런타임에야 에러가 드러난다.
- **QueryDSL**: `order.customer`처럼 실제 필드 참조라, 엔티티 필드명이 바뀌면 컴파일
  에러로 바로 드러난다. 조건을 동적으로 조합하기도(예: 검색 조건별로 `if`문으로
  `BooleanExpression` 추가/제외) JPQL 문자열 조립보다 안전하다.

### Q-class 생성 방식
`annotationProcessor`로 `querydsl-apt`를 등록하면, `javac` 컴파일 시점에 엔티티를
스캔해 `build/generated/sources/annotationProcessor/java/main`에 `QOrder` 등을
자동 생성한다. Gradle Java 플러그인이 이 디렉터리를 자동으로 컴파일 소스에
포함시켜주므로 별도 source set 설정이 필요 없다. `QOrder.order`처럼 엔티티당
싱글턴 인스턴스가 생성되어, 정적 임포트(`import static
io.hkarling.practice.domain.QOrder.order;`)로 바로 쿼리에 쓸 수 있다.

### Spring Data JPA + QueryDSL 조합 패턴 — 커스텀 리포지토리 프래그먼트
Spring Data JPA 리포지토리 인터페이스에 QueryDSL 쿼리를 끼워 넣으려면:
1. 커스텀 메서드를 선언한 인터페이스(`OrderQueryRepository`)를 만들고
2. **인터페이스명 + `Impl`** 규칙으로 구현체(`OrderQueryRepositoryImpl`)를 만든 뒤
3. 원래 리포지토리(`OrderRepository`)가 `JpaRepository`와 이 커스텀 인터페이스를
   함께 상속하게 한다.

Spring Data JPA가 이 네이밍 규칙(`Impl` 접미사)으로 구현체를 자동 탐색해서
`OrderRepository`의 실제 구현체에 이 메서드들을 합쳐 넣는다.

## 진행 내용

### 1. `build.gradle`
```groovy
implementation 'com.querydsl:querydsl-jpa:5.1.0:jakarta'
annotationProcessor 'com.querydsl:querydsl-apt:5.1.0:jakarta'
annotationProcessor 'jakarta.annotation:jakarta.annotation-api'
annotationProcessor 'jakarta.persistence:jakarta.persistence-api'
```

### 2. `JPAQueryFactory` 빈
```java
@Configuration
public class QuerydslConfig {

  @Bean
  public JPAQueryFactory jpaQueryFactory(EntityManager entityManager) {
    return new JPAQueryFactory(entityManager);
  }
}
```

`EntityManager`를 필드 주입(`@PersistenceContext`)이 아니라 **`@Bean` 메서드의
파라미터로 받는 방식**을 택했다. `@Bean` 메서드 파라미터는 Spring이 타입 기준으로
자동 주입해주므로 `@PersistenceContext` 없이도 동작하고, 필드 주입보다 테스트하기
쉽고 의존성이 명시적으로 드러나는 게 요즘 권장되는 스타일이다. 동작은 둘 다 같은
컨테이너 관리 `EntityManager`를 주입받는 것으로 동일.

### 3. 커스텀 리포지토리
```java
public interface OrderQueryRepository {
  List<Order> findAllWithCustomerQuerydsl(Pageable pageable);
}
```

```java
@RequiredArgsConstructor
public class OrderQueryRepositoryImpl implements OrderQueryRepository {

  private final JPAQueryFactory queryFactory;

  @Override
  public List<Order> findAllWithCustomerQuerydsl(Pageable pageable) {
    return queryFactory
        .selectFrom(order)
        .join(order.customer).fetchJoin()
        .orderBy(order.id.desc())
        .offset(pageable.getOffset())
        .limit(pageable.getPageSize())
        .fetch();
  }
}
```

```java
public interface OrderRepository extends JpaRepository<Order, Long>, OrderQueryRepository {

  @Query("SELECT o FROM Order o JOIN FETCH o.customer ORDER BY o.id DESC")
  List<Order> findAllWithCustomer(Pageable pageable);
}
```

`OrderRepository`가 JPQL 버전(`findAllWithCustomer`, 챕터 6)과 QueryDSL 버전
(`findAllWithCustomerQuerydsl`, 이번 챕터)을 **둘 다 갖고 있다** — 하나를 대체한 게
아니라 비교를 위해 나란히 남겨뒀다.

### 4. 결과 — 생성된 SQL

```sql
select
    o1_0.id, o1_0.created_at, o1_0.customer_id,
    c1_0.id, c1_0.city, c1_0.created_at, c1_0.email,
    c1_0.name, c1_0.state, c1_0.updated_at, c1_0.zip_code,
    o1_0.ordered_at, o1_0.status, o1_0.updated_at
from
    orders o1_0
join
    customers c1_0
        on c1_0.id=o1_0.customer_id
order by
    o1_0.id desc
offset
    ? rows
fetch
    first ? rows only
```

**해설**
- LOG006의 JPQL fetch join과 **컬럼 구성, JOIN 구조가 완전히 동일한 1개 쿼리**로
  나갔다. 이후 `2-1`~`2-20`까지 20건의 customer 접근에서 추가 `SELECT`가 전혀
  없었다 — QueryDSL로 작성해도 fetch join의 효과(N+1 → 1)는 동일하게 재현된다.
- 미세한 차이 하나: LOG006의 JPQL 버전은 `offset` 절 없이 `fetch first ? rows only`만
  나갔는데, 이번 QueryDSL 버전은 `offset ? rows`(값 0)가 명시적으로 붙었다.
  `.offset(pageable.getOffset())`을 항상 호출해서 생기는 차이로, `OFFSET 0`은
  no-op이라 기능적으로는 동일하다 — 생성된 SQL 텍스트만 살짝 다른 수준.

## 시행착오 / Q&A

**Q. `@PersistenceContext` 필드 주입 대신 `@Bean` 메서드 파라미터로 `EntityManager`를
받아도 되나?**
A. 된다. `@Bean` 메서드 파라미터는 Spring이 타입으로 자동 주입해주기 때문에
`@PersistenceContext`가 필요 없다. 필드 주입보다 테스트 용이성과 의존성 명시성
측면에서 권장되는 방식이라 이쪽을 채택했다.

## 최종 구성

| 파일 | 변경 |
|---|---|
| `build.gradle` | QueryDSL(jakarta) 의존성 + APT 프로세서 4줄 추가 |
| `src/main/java/.../infra/QuerydslConfig.java` | 신규 — `JPAQueryFactory` 빈 |
| `src/main/java/.../infra/OrderQueryRepository.java` | 신규 — 커스텀 리포지토리 인터페이스 |
| `src/main/java/.../infra/OrderQueryRepositoryImpl.java` | 신규 — QueryDSL 구현체 |
| `src/main/java/.../infra/OrderRepository.java` | `OrderQueryRepository` 상속 추가 |
| `src/test/java/.../infra/QuerydslFetchJoinTest.java` | 신규 |

`QOrder`, `QCustomer` 등은 파일로 존재하지 않고 `build/generated/sources/...`에
빌드 시 자동 생성되므로 최종 구성에서 제외.

## ADR

### Decision
- JPQL `@Query`와 QueryDSL을 하나를 골라 없애지 않고 **둘 다 리포지토리에 유지**한다.
  간단한 고정 쿼리는 JPQL로 충분하고, 조건이 동적으로 조합돼야 하거나(챕터 9. 다중
  조건 필터링) 타입 안정성이 중요한 곳에는 QueryDSL을 선택적으로 쓴다.

### Drivers
- 두 방식이 동일한 SQL을 만들어내는지 직접 검증할 필요가 있었고, QueryDSL의 진짜
  강점(동적 조건 조합)은 다음 챕터(다중 조건 필터링)에서 본격적으로 드러날 것이라
  이번엔 "같은 쿼리를 다르게 작성"하는 것에 집중

### Alternatives considered
- `@EntityGraph`(LOG006에서 언급) — 여전히 비교 대상으로 남겨둠, 아직 실습 안 함

### Consequences
- `OrderRepository`에 같은 목적의 메서드가 JPQL/QueryDSL 두 버전으로 공존 —
  실무였다면 하나로 정리했겠지만, 학습 목적상 비교 자료로 의도적으로 유지

### Follow-ups
- 챕터 9(Phase 3) — 다중 조건 필터링에서 QueryDSL의 동적 쿼리 조합 능력을 본격적으로
  활용
