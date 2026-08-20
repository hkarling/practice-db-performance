# LOG001 — 엔티티 및 스키마 DDL

## 배경 / 목표

Olist 스키마 기반 9개 테이블(`customers`, `sellers`, `categories`, `products`, `orders`,
`order_items`, `order_payments`, `order_reviews`, `delivery`)의 DDL을 작성하고, 대응하는 JPA
엔티티를 매핑한다. LOG000에서 정한 `ddl-auto: validate` 전략이 실제로 잘 동작하는지 이 단계에서
검증한다.

## 진행 내용

### 1. `db/schema.sql`

9개 테이블 + `updated_at` 자동 갱신 트리거(`set_updated_at()` + `BEFORE UPDATE`)로 구성.
FK는 걸되 FK 컬럼에 인덱스는 만들지 않음(Phase 1 인덱스 실습을 위해 의도적으로 비워둠).
`db/schema.sql`은 `src/main/resources` 밖(프로젝트 루트)에 둬서 Spring의 클래스패스 스캔
대상에서 제외 — 스키마는 최초 1회만 수동으로 적용하는 전략.

### 2. 엔티티 9개 + enum 3개

`domain` 패키지에 `Customer`, `Seller`, `Category`, `Product`, `Order`, `OrderItem`,
`OrderPayment`, `OrderReview`, `Delivery`와 `OrderStatus`, `PaymentType`, `PaymentStatus` 작성.
`@NoArgsConstructor(access = PROTECTED)` + `@Getter`만 두고 setter/builder는 아직 없음(엔티티를
직접 생성할 app 계층이 없는 단계라 보류).

## 시행착오 / Q&A

**Q. 로컬에서 `psql -h localhost ...` 명령이 안 먹는다.**
A. 로컬에 `psql` 클라이언트 자체가 설치돼 있지 않은 게 원인. 컨테이너 안에는 Postgres와 함께
`psql`이 있으므로, `docker exec -i <container> psql -U practice -d practice_db_performance < db/schema.sql`
처럼 로컬 파일을 컨테이너 내부 `psql`의 표준입력으로 흘려보내는 방식을 안내. 실제로는 별도
클라이언트로 접속해서 스크립트를 실행하는 방식으로 최종 적용.

**Q. `schema.sql`을 두면 Spring 부팅 시 자동으로 실행되는 거 아닌가?**
A. 아니다. `spring.sql.init`은 기본값(`mode: embedded`)에서 H2 같은 임베디드 DB에서만 자동
실행되고 Postgres 같은 외장 DB는 기본적으로 skip된다. 게다가 `db/schema.sql`은 의도적으로
`src/main/resources` 밖에 둬서 애초에 클래스패스 스캔 대상도 아니다 — 스키마는 "최초 1회 수동
적용"이라는 DB 환경 전략과 맞물린 결정.

**Q. 엔티티 1차 작성본 리뷰에서 발견된 문제 5가지**

| # | 문제 | 영향 |
|---|---|---|
| 1 | `Customer`/`Order` 제외 7개 엔티티에 `created_at`/`updated_at`의 `insertable/updatable=false` 누락 | JPA가 INSERT에 `NULL`을 명시적으로 포함시켜 첫 저장마다 `NOT NULL` 위반 (DB `DEFAULT now()`는 컬럼이 INSERT에서 빠졌을 때만 적용됨) |
| 2 | `OrderPayment`에 `payment_value` 필드 자체가 없음 | 결제 금액을 저장/조회할 방법이 없고, JPA insert 시 NOT NULL 위반 |
| 3 | `OrderItem.price`/`freightValue`가 `Double`로 매핑 | `NUMERIC(10,2)`와 타입 불일치로 `ddl-auto: validate` 실패 가능성 + 금액 부동소수점 오차 |
| 4 | `OrderPayment.paymentType`/`status`에 `length=20` 누락 | `@Column` 기본 길이 255 vs 실제 컬럼 `VARCHAR(20)` 불일치로 validate 실패 가능성 |
| 5 | `Delivery.order`가 `@ManyToOne`으로 매핑 | 스키마상 `order_id`가 `UNIQUE`라 실제론 1:1 관계, `@OneToOne`이어야 함 |

전부 수정 후 재검토 완료, `./gradlew bootRun` 기동 확인까지 통과.

**Q. `TIMESTAMPTZ` 컬럼을 매핑할 때 `OffsetDateTime` 대신 `Instant`를 쓰면 안 되나?**
A. 담고 있는 정보량은 완전히 동일하다. Postgres `TIMESTAMPTZ`는 저장 시점에 무조건 UTC로
정규화해서 저장하고 오프셋 자체는 저장하지 않는다(내부적으로 2000-01-01 UTC 기준 마이크로초
하나만 저장). `OffsetDateTime`으로 읽을 때 붙는 오프셋은 그 순간 JDBC 세션의 타임존 설정에
따라 계산되는 값이지, row에 박혀 있던 실제 데이터가 아니다. 그래서 두 타입 중 뭘 써도 데이터
정확성 차이는 없다.

`OffsetDateTime`을 택한 실질적 이유는 두 가지:
1. JPA 2.2가 `TIMESTAMP WITH TIME ZONE` 매핑용으로 스펙에 명시한 공식 `java.time` 타입이
   `OffsetDateTime`이다(`Instant`는 Hibernate 확장이지 JPA 스펙 목록엔 없음).
2. 오프셋을 필드에 바로 들고 있어서 화면 표시할 때 별도 변환이 필요 없다.

반대로 `Instant`가 더 "정직한" 선택이라는 논리도 있다 — 저장 안 된 오프셋을 마치 의미 있는
데이터처럼 들고 다니지 않기 때문. 둘 다 유효한 선택이라 이 프로젝트에선 관행/편의성 쪽을
택했다.

**Q. DB `TIMESTAMPTZ`가 "서버 시각(오프셋 포함)"을 저장하는 거 아닌가?**
A. 아니다. `now()`나 오프셋 붙은 문자열을 INSERT하면 Postgres가 즉시 UTC로 변환해서 저장하고
오프셋은 버린다. 세션의 `timezone` 설정은 저장에는 관여하지 않고, (a) 오프셋 없는 리터럴을
해석하는 기준, (b) SELECT 결과를 텍스트로 보여주는 렌더링 기준으로만 쓰인다. 즉 "서버 시간대"는
입출력 시점의 해석 렌즈일 뿐, row에 저장되는 데이터가 아니다.

**Q. 이 UTC 정규화 동작이 `@CreationTimestamp` 같은 JPA 어노테이션으로 넣을 때와 다른가?**
A. 아니다, 동일하다 — UTC 정규화는 `TIMESTAMPTZ` 컬럼 타입 자체의 성질이라, 값을 누가
채워서 보내든(Hibernate가 `@CreationTimestamp`로 만든 `OffsetDateTime`이든, DB의
`DEFAULT now()`/트리거든) Postgres 저장 단계에서 항상 동일하게 UTC로 정규화된다.

다만 두 방식 사이의 진짜 차이는 UTC 정규화가 아니라 다음 두 가지다:
1. **기준 시계**: `@CreationTimestamp`는 JVM(애플리케이션 서버)의 시계를 기준으로 `persist()`
   시점에 값을 만들고, DB `DEFAULT`/트리거는 DB 서버의 시계를 기준으로 값을 만든다. 로컬
   단일 머신에서는 둘이 같지만, 개념적으로는 다른 시계다.
2. **적용 범위**: `@CreationTimestamp`는 Hibernate로 `persist()`할 때만 동작한다. 이 프로젝트는
   500만~1500만 row급 시드를 raw SQL/COPY로 넣을 예정이라 그 경로에서는 애초에 Hibernate가
   관여하지 않으므로 `@CreationTimestamp`가 전혀 발동하지 않는다. 반면 DB
   `DEFAULT`/트리거는 INSERT/UPDATE가 어떤 경로(JPA, raw SQL, COPY)로 들어오든 예외 없이
   적용된다 — 이게 LOG000에서 타임스탬프 소유권을 애플리케이션이 아니라 DB로 둔 실질적 이유다.

## 최종 구성

```
domain
├── Customer.java / Seller.java / Category.java / Product.java
├── Order.java / OrderItem.java / OrderPayment.java / OrderReview.java / Delivery.java
├── OrderStatus.java (PROCESSING/SHIPPED/DELIVERED/CANCELLED/REFUNDED)
├── PaymentType.java (CREDIT_CARD/BOLETO/VOUCHER/DEBIT_CARD)
└── PaymentStatus.java (PAID/REFUNDED)
```

`db/schema.sql`은 리포지토리 루트, `psql` 또는 `docker exec` 경유로 로컬 Postgres에 1회 적용.

## ADR

### Decision
- `created_at`/`updated_at`은 모든 엔티티에서 `insertable=false, updatable=false`로 통일 — 값은
  전적으로 DB(`DEFAULT`/트리거)가 소유
- 금액 컬럼(`price`, `freight_value`, `payment_value`)은 전부 `BigDecimal`
- `CHECK` 제약이 걸린 `VARCHAR` enum 컬럼은 실제 길이(`length=20`)를 엔티티에도 명시
- 1:1 관계(`Delivery`-`Order`)는 `@OneToOne`으로 명시

### Drivers
- `ddl-auto: validate`가 타입/길이 불일치를 실제로 걸러낸다는 걸 이번에 확인 — 다만
  `insertable` 누락처럼 validate가 못 잡는 런타임 이슈(첫 INSERT에서만 드러남)도 있어서, 엔티티
  작성 후엔 스키마 diff만 믿지 말고 필드 단위로 리뷰가 필요하다는 걸 확인함
- 금액은 정확한 십진 연산이 필요(Phase 3 매출 집계에서 부동소수점 오차 누적 방지)

### Alternatives considered
- `@CreationTimestamp`/`@UpdateTimestamp` Hibernate 어노테이션 — 기각(LOG000에서 이미 결정:
  대용량 시드는 JPA 경로를 안 타므로 타임스탬프 소유권을 DB 트리거로 일원화한 것과 일관성 유지)

### Consequences
- 엔티티에 setter/builder가 없어 아직 JPA로 새 row를 만들 수 없음 — app 계층 작성 시 생성자
  또는 빌더 방식을 결정해야 함
- `ddl-auto: validate`는 타입/길이는 잡아주지만 nullable 값 자체의 유효성(예: 매핑 누락)까진
  보장하지 않는다는 한계를 인지한 채로 다음 단계 진행

### Follow-ups
- 서비스/리포지토리 계층에서 엔티티 생성 방식(생성자 vs 빌더) 결정
- 시드 데이터 생성기(`seed/`, Python + Faker) 작성
