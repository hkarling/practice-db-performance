# LOG005 — N+1 문제 재현

## 배경 / 목표

Phase 2 챕터 5. `Order.customer`(`@ManyToOne(fetch = LAZY)`)를 이용해 N+1 문제를 실제로 재현하고, SQL 로그로 정확히 몇 번의 쿼리가 나가는지 확인한다.

## 개념

### N+1 문제란

부모 엔티티 N개를 조회 (쿼리 1번)한 뒤, 각 부모가 참조하는 연관 엔티티에 접근할 때마다 추가 쿼리가 나가는 현상. 총 `1(부모 목록) + N(각 부모의 연관 엔티티)`번의 쿼리가 발생한다.
`@ManyToOne(fetch = FetchType.LAZY)`로 매핑된 연관관계는 프록시 객체만 채워진 채로 로딩되고, `getCustomer().getName()`처럼 실제 필드에 접근하는 순간에야
Hibernate가 그 프록시를 초기화하기 위한 `SELECT`를 추가로 날린다. 이걸 반복문 안에서 하면 N번 터진다.

### `open-in-view: false`와 지연 로딩의 관계

`application.yaml`에 `open-in-view: false`가 설정돼 있으면 (OSIV 비활성화), **트랜잭션이 열려 있는 동안에만** 지연 로딩이 가능하다 — 트랜잭션/세션이 끝난 뒤 지연 필드에
접근하면 `LazyInitializationException`이 발생한다. OSIV를 켜두면 N+1이 컨트롤러/뷰 레벨까지 조용히 새서 진짜 원인 파악이 어려워지므로, 꺼두는 게 좋은 설정이다. 이 프로젝트는 이미
꺼져 있어서, 재현 테스트도 트랜잭션 안에서 실행해야 한다.

### `@DataJpaTest` vs `@SpringBootTest`

- `@DataJpaTest`: JPA 관련 auto-configuration만 로드하는 "슬라이스 테스트". 각 테스트 메서드를 자동으로 트랜잭션으로 감싸고 끝나면 롤백한다. 다만 로드하는
  auto-configuration 범위가 제한적이라, `spring-boot-docker-compose`처럼 슬라이스 밖의 모듈은 활성화되지 않는다.
- `@SpringBootTest`: 전체 애플리케이션 컨텍스트를 로드한다. `bootRun`과 동일하게 docker-compose 자동 연동이 동작하지만, 트랜잭션 자동 래핑은 안 해주므로 지연 로딩을 위해
  `@Transactional`을 직접 붙여야 한다 (읽기 전용이라 롤백돼도 상관없음).

## 설계 결정 — 왜 Testcontainers를 안 썼는가

이 프로젝트엔 Spring Initializr가 생성해준 `TestcontainersConfiguration`(`PostgreSQLContainer` + `@ServiceConnection`)이 이미 있고,
`ApplicationTests`가 이를 사용 중이다. N+1 재현에도 처음엔 이 방향을 검토했다.

**Testcontainers로 갔을 때의 문제**: 매번 새 빈 컨테이너로 뜨기 때문에 `db/schema.sql`
적용 + 소규모 픽스처 데이터를 직접 넣어야 한다. N+1 자체 (쿼리 개수 패턴)는 데이터 규모와 무관해 이것만으로는 문제없지만, **다음 챕터들 (6. fetch join으로 해결, 7. batch size
트레이드오프)은 실제 스케일에서 체감되는 성능 차이를 보는 게 목적**이라 결국 로컬 Postgres (500만 건 시드 데이터)가 필요해진다. 챕터마다 DB 전략을 왔다갔다 하는 것보다 Phase 2 전체를 로컬
Postgres로 통일하기로 결정.

**`TestcontainersConfiguration`이 불필요해진 게 아니다**: `ApplicationTests`처럼 순수
"컨텍스트가 정상적으로 뜨는가" 같은 기능/구조 검증에는 격리된 Testcontainers가 여전히 맞는 도구다. README의 원래 원칙 (Testcontainers = 기능/결과 검증 전용, 로컬
Postgres = 쿼리 성능/동작 관찰 전용)을 그대로 따른 결과일 뿐, 둘 다 각자의 용도로 계속 쓰인다.

## 진행 내용

### 1. `OrderRepository` 추가

```java
package io.hkarling.practice.infra;

import io.hkarling.practice.domain.Order;
import org.springframework.data.jpa.repository.JpaRepository;

public interface OrderRepository extends JpaRepository<Order, Long> {

}
```

### 2. 로컬 Postgres를 테스트에서 쓰기 위한 설정 변경

`developmentOnly`로 선언된 `spring-boot-docker-compose`는 `bootRun` 전용 클래스패스라 테스트에선 아예 로드되지 않는다. `build.gradle`에 테스트용으로 별도
추가:

```groovy
testImplementation 'org.springframework.boot:spring-boot-docker-compose'
```

이것만으로는 부족했다 — Spring Boot는 테스트에서 docker-compose 자동 연동을 **기본적으로 스킵**하도록 설계돼 있다 (`spring.docker.compose.skip.in-tests` 기본값
`true`). 이는
"테스트는 격리되고 재현 가능해야 한다"는 설계 원칙 때문 — 일반적인 테스트는 Testcontainers 같은 임시 컨테이너를 쓰는 게 정석이고, 오래 살아있는 공유 상태 (docker-compose 서비스)를
테스트가 자동으로 물어오면 격리성이 깨지기 때문이다. 우리는 의도적으로 재사용하려는 예외 케이스라 명시적으로 꺼야 한다. **빌드 → 운영 배포 시 스킵과는 무관하다** — 그건
`developmentOnly` Gradle 구성이 이미 담당한다 (운영 jar엔 이 모듈 자체가 안 실림).

`src/main/resources/application.yaml`:

```yaml
spring:
  docker:
    compose:
      lifecycle-management: start-only
      skip:
        in-tests: false
  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false
    show-sql: true
    properties:
      hibernate:
        format_sql: true

logging:
  level:
    org.hibernate.SQL: debug
    org.hibernate.orm.jdbc.bind: trace
```

`logging.level` 방식을 추가한 이유: 기존 `show-sql: true`는 바인딩 파라미터 값을 안 보여줘서 (`customer_id = ?`로만 나옴) 실제로 어떤 값으로 쿼리가 나갔는지 확인하기
어려웠다. `org.hibernate.orm.jdbc.bind: trace`를 추가하면 실제 바인딩된 값이 로그에 찍힌다.

### 3. 재현 테스트

```java
package io.hkarling.practice.infra;

import static org.assertj.core.api.Assertions.assertThat;

import io.hkarling.practice.domain.Order;
import lombok.extern.slf4j.Slf4j;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.transaction.annotation.Transactional;

@Slf4j
@SpringBootTest
@Transactional
class NPlusOneTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("주문 목록 조회 후 각 주문의 customer에 접근하면 N+1 쿼리가 발생한다")
  void findOrders_thenAccessLazyCustomer_triggersNPlusOneQueries() {
    log.info("========== 1. 주문 목록 조회 (쿼리 1번) ==========");
    Page<Order> orders = orderRepository.findAll(PageRequest.of(0, 20));

    int i = 0;
    for (Order order : orders) {
      log.info("---------- 2-{}. order id={}의 customer 접근 (LAZY 초기화 시도) ----------",
          ++i, order.getId());
      assertThat(order.getCustomer().getName()).isNotBlank();
    }
  }
}
```

### 4. 결과 — 총 22번의 SELECT

```
========== 1. 주문 목록 조회 (쿼리 1번) ==========
select o1_0.id, ... from orders o1_0 offset ? rows fetch first ? rows only   -- 1
select count(o1_0.id) from orders o1_0                                       -- 1 (Page 부수 효과)

---------- 2-1. order id=4308697의 customer 접근 ----------
select c1_0.id, ... from customers c1_0 where c1_0.id=?  -- binding: 357807   -- 1
---------- 2-2. order id=4308698의 customer 접근 ----------
select c1_0.id, ... from customers c1_0 where c1_0.id=?  -- binding: 547801   -- 1
... (2-3 ~ 2-20까지 동일 패턴, customer_id 전부 서로 다른 값)
```

**해설**

- **주문 목록 1번 + customer 20번 = 정확히 21번**, 전형적인 `1 + N` 패턴이 그대로 재현됐다.
- **부수적으로 확인된 것**: `findAll(Pageable)`(`Page<Order>` 반환)을 쓰면 전체 개수를 세는 `SELECT count(*) FROM orders` 쿼리가 **별도로 1번 더**
  나간다. N+1과는 다른 문제지만 같이 딸려오는 흔한 함정 — 페이지네이션 챕터 (11)에서 다시 다룰 주제. 최종 총 쿼리 수는 22번.
- **1차 캐시 효과는 이번엔 발생 안 함**: 바인딩된 customer_id 20개를 확인해보니 전부 서로 다른 값이었다 — 100만 명 중 무작위로 뽑힌 주문 20건이 우연히 같은 고객일 확률이 사실상 0에
  가까웠기 때문. 만약 겹치는 고객이 있었다면 Hibernate 1차 캐시 덕분에 그 고객에 대한 중복 쿼리는 안 나갔을 것.
- 로그를 보면 각 쿼리가 콘솔에 두 번씩 찍히는데, 이건 실제 DB 왕복이 두 번이라서가 아니라 `org.hibernate.SQL`(새로 추가한 방식)과 `show-sql: true`(기존 방식)가 같은 쿼리를
  각자 한 번씩 출력해서다 — 중복 로거라 나중에 `show-sql: true`는 정리 대상.

## 시행착오 / Q&A

**Q. Spring Boot 4.1.0에서 `@DataJpaTest`/`@AutoConfigureTestDatabase` import 경로가
`org.springframework.boot.test.autoconfigure.orm.jpa.*`(구버전 관례)가 아니라던데?**
A. 맞다. Boot 4.1부터 테스트 슬라이스 어노테이션이 모듈별로 재편됐다 —
`org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest`,
`org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase`가 맞는 경로. 다만 이번 문제의 원인은 import 경로가 아니라 아래
항목들이었다.

**Q. `@DataJpaTest` + `@AutoConfigureTestDatabase(replace = NONE)`로 했는데
`Failed to determine a suitable driver class` 에러가 났다.**
A. `@DataJpaTest`는 JPA 관련 auto-configuration만 로드하는 슬라이스라
`spring-boot-docker-compose`(로컬 Postgres 연결 정보를 채워주는 모듈)가 애초에 활성화되지 않는다. `replace = NONE`은 "임베디드로 바꿔치기하지 마라"는 뜻이지 "연결
정보를 채워달라"는 뜻이 아니다. `@SpringBootTest`(전체 컨텍스트)로 바꿔야 한다.

**Q. `@SpringBootTest`로 바꿨는데도 같은 에러가 계속 났다.**
A. `spring-boot-docker-compose`가 `developmentOnly`라 애초에 테스트 클래스패스에 없었다. `testImplementation`으로 별도 추가해야 한다. 같은 좌표를
`developmentOnly`와
`testImplementation` 양쪽에 선언해도 문제없다 — 서로 다른 Gradle 구성이라 각자 별도 클래스패스를 만든다.

**Q. 의존성을 추가했는데도 또 같은 에러가 났다.**
A. `spring.docker.compose.skip.in-tests` 기본값이 `true`라 테스트에서 자동 스킵된다. 명시적으로 `false`로 꺼야 한다.

## 최종 구성

| 파일                                                            | 변경                                                                                               |
|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `src/main/java/io/hkarling/practice/infra/OrderRepository.java` | 신규                                                                                               |
| `src/test/java/io/hkarling/practice/infra/NPlusOneTest.java`    | 신규                                                                                               |
| `build.gradle`                                                  | `testImplementation 'org.springframework.boot:spring-boot-docker-compose'` 추가                    |
| `src/main/resources/application.yaml`                           | `spring.docker.compose.skip.in-tests: false`, `logging.level.org.hibernate.SQL/orm.jdbc.bind` 추가 |

## ADR

### Decision

- Phase 2 (JPA/ORM 레벨 문제) 챕터들은 로컬 Postgres (실제 시드 데이터)를 재사용한다.
  `TestcontainersConfiguration`은 그대로 유지하되 `ApplicationTests` 같은 순수 기능/구조 검증용으로만 쓴다.

### Drivers

- N+1 자체는 데이터 규모와 무관하지만, 이어지는 챕터 (fetch join, batch size)는 실제 스케일에서의 성능 체감이 목적이라 로컬 Postgres가 필요함 — Phase 2 전체를 하나의 DB
  전략으로 통일하는 게 챕터마다 왔다갔다 하는 것보다 나음

### Alternatives considered

- Testcontainers + 소규모 픽스처 — 격리성은 더 좋지만 스키마 적용 + 픽스처 코드가 추가로 필요하고, 다음 챕터에서 다시 로컬 Postgres로 돌아와야 해서 기각

### Consequences

- 테스트가 로컬 Postgres (공유 상태)에 의존하게 됨 — `@Transactional`로 각 테스트 종료 시 롤백되므로 데이터를 변경하지 않는 한 (현재는 조회만 함) 안전
- `spring.docker.compose.skip.in-tests: false`가 프로젝트 전역 설정이라, 앞으로 작성될 모든 `@SpringBootTest`가 기본적으로 로컬 Postgres에 연결됨 — 격리가
  필요한 테스트는
  `TestcontainersConfiguration`을 명시적으로 `@Import`해서 예외 처리

### Follow-ups

- `show-sql: true`와 `logging.level.org.hibernate.SQL` 로거가 중복 출력됨 — 필요시
  `show-sql: true` 제거
- 챕터 6: fetch join으로 N+1 해결
