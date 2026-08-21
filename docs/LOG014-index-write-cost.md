# LOG014 — 인덱스가 write 성능에 미치는 영향

## 배경 / 목표

Phase 4 챕터 14. 챕터 3, 10, 12에서 계속 예고만 해왔던 "인덱스는 읽기를
빠르게 하지만 쓰기는 느리게 한다"를 실측으로 검증한다. 인덱스 개수를 0개부터
실제 `orders` 테이블과 동일한 4개까지 늘려가며 같은 양의 INSERT 시간을
비교한다.

## 개념

### 모든 인덱스는 매 쓰기마다 같이 갱신된다
테이블에 인덱스가 N개 있으면, 행 하나를 삽입/수정/삭제할 때 테이블 본체(힙)
쓰기 1번 + **인덱스 N개의 B-tree 갱신 N번**이 같이 일어난다. 인덱스가 많을수록:
- INSERT/UPDATE/DELETE가 느려진다.
- 디스크 공간을 더 쓴다(인덱스도 별도의 자료구조).
- B-tree는 정렬된 구조라, 새 값이 중간에 끼어들면 페이지 분할(page split) 같은
  추가 작업이 생길 수 있다.

읽기(SELECT)가 빨라지는 대신 쓰기가 느려지는 트레이드오프 — "인덱스는 많을수록
좋다"가 성립하지 않는 이유.

### 삽입 값의 순서가 B-tree 유지보수 비용에 영향을 준다
B-tree에 **오름차순으로만 증가하는 값**(예: auto-increment PK)을 계속 넣으면
항상 트리의 맨 오른쪽 끝에만 추가되는 형태라, 페이지 분할이나 기존 페이지에 대한
랜덤 쓰기가 거의 없다 — 순차 append에 가깝다. 반면 **무작위 순서의 값**(예:
FK, 정렬 기준과 무관한 컬럼)을 넣으면 매 삽입마다 트리 전체에 흩어진 페이지를
건드려야 해서 페이지 분할이 훨씬 자주 일어난다 — 같은 "인덱스 1개 추가"여도
비용이 크게 다를 수 있다.

## 진행 내용

### 실험 설계 — 임시 테이블로 격리

실제 `orders` 테이블(다른 챕터 실습에도 계속 쓰임)을 건드리지 않기 위해,
구조만 복사한 임시 테이블로 실험했다.

```sql
CREATE TABLE orders_write_test (LIKE orders INCLUDING DEFAULTS INCLUDING IDENTITY);
```

`INCLUDING DEFAULTS`만으로는 `GENERATED ALWAYS AS IDENTITY`(자동 채번)가
안 딸려온다 — 첫 시도에서 `null value in column "id"` 에러가 났다. `IDENTITY`
속성은 일반 `DEFAULT` 표현식과 별개 개념이라 `INCLUDING IDENTITY`를 명시적으로
붙여야 한다는 걸 확인했다.

인덱스는 이 방식으로 전혀 안 딸려오므로, 0개부터 하나씩 직접 추가해가며 같은
INSERT(기존 `orders`에서 50만 건을 그대로 복사)를 반복 측정했다. 각 단계는
`TRUNCATE`로 비우고 → 그 단계까지의 인덱스를 추가하고 → 같은 INSERT를 재실행하는
순서로 진행했다(인덱스는 단계마다 누적 — 이전 단계의 인덱스를 지우지 않고 계속
쌓아감).

**0단계 — 인덱스 없음:**
```sql
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;
```

**1단계 — PK 추가:**
```sql
TRUNCATE orders_write_test;
ALTER TABLE orders_write_test ADD PRIMARY KEY (id);

INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;
```

**2단계 — `customer_id` 인덱스 추가:**
```sql
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_customer_id ON orders_write_test (customer_id);

INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;
```

**3단계 — `status, ordered_at` 복합 인덱스 추가:**
```sql
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_customer_id ON orders_write_test (customer_id);
CREATE INDEX idx_wt_status_ordered_at ON orders_write_test (status, ordered_at DESC);

INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;
```

**4단계 — `ordered_at` 커버링 인덱스 추가 (실제 `orders`와 동일 구성):**
```sql
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_customer_id ON orders_write_test (customer_id);
CREATE INDEX idx_wt_status_ordered_at ON orders_write_test (status, ordered_at DESC);
CREATE INDEX idx_wt_ordered_at_covering_status ON orders_write_test (ordered_at) INCLUDE (status);

INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;
```

정리:
```sql
DROP TABLE orders_write_test;
```

### 결과

| 인덱스 개수 | 구성 | 50만 건 삽입 시간 | 증분 |
|---|---|---|---|
| 0 | (없음) | 1.205s | - |
| 1 | PK(`id`) | 1.556s | +0.351s |
| 2 | + `customer_id` | 2.995s | +1.439s |
| 3 | + `status, ordered_at` (복합) | 5s | +2.005s |
| 4 (실제 `orders`와 동일 구성) | + `ordered_at INCLUDE status` (커버링) | 7s | +2s |

**해설**
- **인덱스 0개 → 4개, 약 5.8배 느려졌다.** 실제 `orders` 테이블이 지금 갖고
  있는 만큼의 인덱스를 그대로 재현한 결과다.
- **증가폭이 균등하지 않다** — PK 추가는 +0.351s인데, `customer_id` 추가는
  +1.439s로 4배 넘게 비싸다. 이유는 삽입되는 값의 순서에 있다:
  - `id`는 `GENERATED ALWAYS AS IDENTITY`라 항상 오름차순으로 증가한다. B-tree에
    계속 오름차순 값을 넣으면 매번 트리의 맨 오른쪽 끝에만 추가되는 형태라(기존
    페이지들을 건드릴 일이 거의 없음), 페이지 분할이나 랜덤 쓰기가 거의 없다 —
    순차 append에 가깝다.
  - `customer_id`(100만 명 중 무작위), `status`/`ordered_at`(원본 데이터를
    그대로 복사, 정렬 기준과 무관)은 삽입되는 값이 B-tree 전체에 흩어져서
    들어간다. 매 삽입마다 트리 여기저기의 페이지를 건드려야 하고 페이지 분할도
    훨씬 자주 일어난다 — 그래서 PK보다 몇 배 더 비쌌다.
- **결론**: "인덱스 몇 개"만이 아니라 **"어떤 값이 어떤 순서로 들어가는가"도
  쓰기 비용에 큰 영향을 준다.** auto-increment PK 같은 순차 값 인덱스는
  상대적으로 저렴하지만, FK/카테고리 컬럼처럼 무작위성이 큰 컬럼의 인덱스는
  쓰기 비용이 눈에 띄게 크다.

### 정리
실험용 `orders_write_test` 테이블은 DROP했다 — 스키마에 영구 반영되지 않음.

## 시행착오 / Q&A

**Q. `LIKE table INCLUDING DEFAULTS`인데 왜 자동 채번(`id`)이 안 됐나?**
A. `GENERATED ALWAYS AS IDENTITY`는 컬럼의 일반 `DEFAULT` 표현식과 별개의
속성이다. `LIKE`절에서 이걸 복사하려면 `INCLUDING IDENTITY`를 명시적으로
추가해야 한다(참고로 새로 생성된 identity는 원본과 별개의 시퀀스를 쓴다).

## 최종 구성

이번 챕터는 실험만 하고 정리했다 — `db/schema.sql`이나 실제 테이블 구조
변경 없음. (실험용 `orders_write_test` 테이블은 DROP 완료.)

## ADR

### Decision
- 인덱스를 추가할 때는 "읽기 이득"만 볼 게 아니라 "쓰기 비용", 특히 **삽입되는
  값이 얼마나 무작위인지**도 같이 고려한다. 지금까지(챕터 3~12) 이 프로젝트에
  추가한 인덱스 4개(`idx_orders_customer_id`, `idx_orders_status_ordered_at`,
  `idx_orders_ordered_at_covering_status`, `idx_order_items_product_id_covering`)는
  전부 챕터 9~12의 실제 조회 성능 문제를 해결하기 위한 근거가 있었으므로 유지한다
  — 이번 챕터는 "그 인덱스들이 공짜가 아니었다"는 걸 정량적으로 확인하는 게
  목적이었지, 인덱스를 줄이자는 결론은 아니다.

### Drivers
- 챕터 3(`idx_orders_status` DROP), 10(커버링 인덱스), 12(집계용 인덱스 추가)를
  거치며 인덱스 개수가 계속 늘어났는데, 그 대가를 실측한 적이 없었음

### Alternatives considered
- 실제 `orders` 테이블에서 직접 인덱스를 DROP/재생성하며 측정 — 다른 챕터
  실습에 영향을 줄 위험이 있어 기각, 구조만 복사한 임시 테이블로 격리하는
  방식을 택함

### Consequences
- 앞으로 인덱스를 추가할 때, 대상 컬럼이 순차적인지(PK류) 무작위인지(FK/카테고리류)를
  고려해 쓰기 비용을 가늠하는 습관이 필요함을 확인
- 프로젝트의 시드 데이터 적재(LOG002, `seed/`)가 유독 빨랐던 이유도 다시
  보인다 — PK 채번을 COPY 순서에 맡기고, 스키마 적용 시점엔 인덱스가 없는
  상태에서 대량 적재 후 인덱스를 나중에 걸었기 때문(챕터 1~4에서 실습을 위해
  순차적으로 인덱스를 추가한 순서 자체가 이미 "쓰기 먼저, 인덱스는 나중에"라는
  이 챕터의 교훈과 일치)

### Follow-ups
- 챕터 15 — VACUUM, ANALYZE
