# LOG002 — 시드 데이터 생성기

## 배경 / 목표

Phase 1 실습(EXPLAIN ANALYZE, 인덱스)을 위해 로컬 Postgres에 대용량 데이터를 한 번 적재한다.
customers 100만 / orders 500만 / order_items 1500만 수준, 주문 상태 분포와 상태 간 일관성
(취소 시 환불 레코드, 배송 정보는 shipped/delivered만, 리뷰는 delivered의 60%만)을 만족해야 한다.

## 진행 내용

### 1. CSV + `COPY` 벌크 로드

Hibernate `save()` 반복으로는 이 규모(수천만 row)를 현실적인 시간 안에 못 넣는다. Python으로
CSV를 생성하고 Postgres `COPY ... FROM STDIN`으로 서버 사이드 벌크 로드하는 방식을 택했다.
이는 LOG000/LOG001에서 이미 정한 "시드는 JPA 경로를 타지 않는다"는 결정과도 일치한다.

### 2. PK 채번을 DB 자동 증가에 맡기고, "COPY 순서 = ID 순서"를 이용

스키마가 `GENERATED ALWAYS AS IDENTITY`라 CSV에 id 컬럼을 넣지 않으면 Postgres가 입력 순서대로
1, 2, 3...을 자동 채번한다. 이를 이용해 customers를 순서대로 COPY하면 N번째 row가 정확히
`id=N`이 된다는 걸 신뢰하고, orders 등에서 `customer_id = random.randint(1, NUM_CUSTOMERS)`처럼
FK를 DB 조회 없이 계산으로 생성했다.

**전제 조건**(반드시 지켜야 함): 테이블이 비어 있는 상태에서 `categories → sellers → customers →
products → orders → order_items/order_payments/order_reviews/delivery` 순서로 한 번에 COPY해야
한다. 중간에 실패하면 이어서 재시도하지 않고 `TRUNCATE ... RESTART IDENTITY CASCADE`로 전체
초기화 후 재실행해야 한다.

### 3. orders 관련 5개 테이블을 한 루프에서 동시 스트리밍 생성

`gen_orders.py`가 order 500만 건을 순회하면서 `orders.csv`, `order_items.csv`,
`order_payments.csv`, `order_reviews.csv`, `delivery.csv` 5개 파일에 동시에 append한다.
상태 간 일관성(취소/환불 시 payment REFUNDED, 배송 정보는 shipped/delivered만, 리뷰는
delivered의 60%만)을 그 자리에서 보장하기 위한 구조.

### 4. 스펙에 명시 안 된 테이블 규모 가정

- categories: 50 (고정 리스트, 스케일 다운 대상 아님)
- sellers: 5만
- products: 20만

### 5. Faker 로케일: `pt_BR`

Olist가 브라질 데이터셋이고, 브라질 주(state) 약어가 정확히 2글자(SP, RJ...)라
`state VARCHAR(2)` 스키마와 자연스럽게 맞아 선택.

### 6. 스모크 테스트용 스케일 다운

`SEED_SCALE_DOWN` 환경변수로 전체 카운트를 나눠서(기본 1, 스모크 테스트 시 1000) 실행 가능하게
구성 — 수십 분짜리 풀 스케일 실행 전에 로직 오류를 빠르게 잡기 위함.

## 실행 방법

로컬 Postgres(docker compose)가 기동 중이고 `db/schema.sql`이 이미 적용되어 있어야 한다.

```bash
cd seed
python -m venv .venv
.venv\Scripts\activate          # Windows PowerShell
pip install -r requirements.txt
```

DB 접속 정보는 기본값(`localhost:5432`, db `practice_db_performance`, user/password `practice`)을
쓰며, 다르게 접속해야 하면 `SEED_DB_HOST` / `SEED_DB_PORT` / `SEED_DB_NAME` / `SEED_DB_USER` /
`SEED_DB_PASSWORD` 환경변수로 덮어쓴다(`config.py` 참고).

```bash
# 스모크 테스트: 전체 규모의 1/1000로 축소해 로직 오류를 먼저 확인
$env:SEED_SCALE_DOWN = "1000"   # PowerShell (bash면 SEED_SCALE_DOWN=1000)
python run_all.py

# 문제 없으면 초기화 후 풀 스케일 실행
$env:SEED_SCALE_DOWN = "1"      # 또는 환경변수 자체를 unset (기본값 1)
python run_all.py
```

`run_all.py`는 (1) `gen_categories/gen_sellers/gen_customers/gen_products/gen_orders`를 순서대로
호출해 `output/*.csv`를 생성하고, (2) 같은 순서로 각 테이블에 `COPY`를 실행한다. 이 순서는
FK 무결성(및 "COPY 순서 = ID 순서" 전제) 때문에 반드시 지켜야 한다 — 순서를 바꾸거나 일부만
재실행하면 안 된다.

재실행이 필요하면(스모크 → 풀 스케일 전환 포함) 먼저 테이블을 비워야 한다:

```sql
TRUNCATE categories, sellers, customers, products, orders,
  order_items, order_payments, order_reviews, delivery
  RESTART IDENTITY CASCADE;
```

## 시행착오 / Q&A

**Q. `requirements.txt` 대신 `pyproject.toml`로 관리하는 게 낫지 않나?**
A. 도구에 따라 다르다. 순수 `pip + venv`로는 `pyproject.toml`을 넣어도 `[build-system]`/
`[project]` 메타데이터만 늘고 실질 이득이 없다(이 폴더는 설치할 패키지가 아니라 스크립트
모음). `uv`를 쓴다면 `pyproject.toml` + lockfile이 기본 워크플로우라 이득이 크지만, 이번
프로젝트는 `uv`를 도입할 필요가 없다고 판단해 `pip + requirements.txt`를 유지하기로 결정.

**Q. 직접 작성한 `gen_customer.py`에서 실행이 안 된다.**
A. 두 가지 문제: (1) `if __name__ == "__main__":` 블록의 `generate()` 호출에 들여쓰기가
빠져 `IndentationError`, (2) 파일명이 `gen_categories`/`gen_sellers`와 다르게 단수형
(`gen_customer.py`)이라 다른 모듈들과 명명 규칙이 어긋남. `gen_customers.py`로 재작성하고
기존 파일은 삭제.

## 최종 구성

풀 스케일 실행 후 실제 row 수:

| 테이블 | 목표 | 실제 |
|---|---|---|
| categories | 50 | 50 |
| sellers | 50,000 | 50,000 |
| products | 200,000 | 200,000 |
| customers | 1,000,000 | 1,000,000 |
| orders | 5,000,000 | 5,000,000 |
| order_items | ~15,000,000 | 14,999,562 |
| order_payments | 5,000,000 (1/order) | 5,000,000 |
| delivery | ~4,000,000 (80%) | 4,001,334 |
| order_reviews | ~2,100,000 (delivered의 60%) | 2,100,394 |

일관성 검증 쿼리 결과:
- `orders.status` 분포: DELIVERED 70.00% / SHIPPED 10.02% / CANCELLED 7.99% / PROCESSING 7.00% /
  REFUNDED 4.98% — 목표 분포와 일치
- `order_payments.status`: `CANCELLED`/`REFUNDED` 주문은 전부 `REFUNDED`, 나머지는 전부 `PAID`
- `delivery`: `SHIPPED`/`DELIVERED` 주문에만 존재, 다른 상태는 0건
- `order_reviews`: `DELIVERED` 주문에만 존재, 다른 상태는 0건

## ADR

### Decision
- 시드 데이터는 Python(Faker) → CSV → Postgres `COPY`로 적재 (JPA/ORM 경로 사용 안 함)
- PK는 `GENERATED ALWAYS AS IDENTITY`의 COPY 순서 기반 자동 채번에 의존, 애플리케이션에서
  ID를 직접 관리하지 않음
- orders와 연관된 4개 테이블(order_items/order_payments/order_reviews/delivery)은 단일
  스트리밍 루프에서 동시 생성해 상태 일관성을 구조적으로 보장
- categories(50)/sellers(5만)/products(20만)는 스펙에 없어 임의로 정한 값

### Drivers
- 수천만 row 규모에서 ORM 경로는 현실적인 시간 안에 끝나지 않음
- FK 무결성을 위해 매번 DB에서 실제 ID를 조회하면 생성 속도가 크게 느려짐 — COPY 순서 기반
  추론으로 조회 없이 FK를 계산

### Alternatives considered
- `psycopg2.extras.execute_values`로 batch INSERT — 기각. `COPY`보다 느리고, 수천만 row에서
  체감 차이가 큼
- 랜덤 UUID PK — 기각. FK 계산을 위해 어차피 순번 정보가 필요하고, BIGINT IDENTITY가 인덱스
  크기/조인 성능 실습(Phase 1~3)에 더 적합

### Consequences
- 이 세팅은 "빈 테이블 + 정해진 순서로 한 번에 COPY"에만 안전하다. 부분 재실행/재시드가
  필요하면 반드시 전체 `TRUNCATE ... RESTART IDENTITY CASCADE` 후 재실행해야 함 — 스크립트
  자체는 이 전제를 강제하지 않으므로 사람이 기억해야 하는 제약
- `seed/output/`의 CSV(수 GB 규모)와 `seed/.venv/`는 `.gitignore`에 추가해 커밋 대상에서 제외

### Follow-ups
- Phase 1 실습(EXPLAIN ANALYZE, 인덱스 없는 슬로우 쿼리 재현) 진행
