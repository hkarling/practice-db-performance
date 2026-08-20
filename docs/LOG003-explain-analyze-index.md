# LOG003 — EXPLAIN ANALYZE 기본 & 단일 컬럼 인덱스

## 배경 / 목표

Phase 1 챕터 1~3. 인덱스가 하나도 없는(PK 제외) `orders`(500만 행) 테이블을 대상으로
`EXPLAIN ANALYZE` 읽는 법을 익히고, 단일 컬럼 인덱스가 쿼리 선택도(selectivity)에 따라
얼마나 다른 효과를 내는지 직접 관찰한다.

- 챕터 1: EXPLAIN ANALYZE 기본 — Seq Scan vs Index Scan
- 챕터 2: 인덱스 없는 상태에서 슬로우 쿼리 재현
- 챕터 3: 단일 컬럼 인덱스 추가 후 비교

## 진행 내용

두 쿼리로 실험했다: **쿼리 A**(`status = 'DELIVERED'`, 선택도 낮음 — 전체의 70%),
**쿼리 B**(`customer_id = 12345`, 선택도 매우 높음 — 1건).

### 1. 베이스라인 — 쿼리 A, 인덱스 없음

```sql
EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'DELIVERED';
```

```
Seq Scan on orders  (cost=0.00..113660.10 rows=3471339 width=49) (actual time=1.775..484.802 rows=3500112 loops=1)
  Filter: ((status)::text = 'DELIVERED'::text)
  Rows Removed by Filter: 1499888
Planning Time: 0.061 ms
JIT:
  Functions: 2
  Options: Inlining false, Optimization false, Expressions true, Deforming true
  Timing: Generation 0.152 ms (Deform 0.051 ms), Inlining 0.000 ms, Optimization 0.191 ms, Emission 1.564 ms, Total 1.908 ms
Execution Time: 594.588 ms
```

**해설**
- `cost=0.00..113660.10`: 시작 비용 0.00은 Seq Scan이 준비 작업 없이 첫 페이지부터 바로
  읽기 시작하기 때문. 이 숫자는 ms가 아니라 페이지 접근/튜플 처리에 대한 상대적 가중치를
  더한 **추상적인 비용 단위**다 — 플랜 후보들을 서로 비교하기 위한 값.
- `rows=3471339`(추정) vs `actual rows=3500112`(실측): 오차 0.8% — `orders` 테이블 통계
  (`pg_stats`)가 최신이라는 뜻. 옵티마이저의 판단이 정확한 추정 위에서 내려졌다는 근거.
- `Rows Removed by Filter: 1499888`: `3500112 + 1499888 = 5000000`으로 테이블 전체 행
  수와 정확히 일치 — Seq Scan은 조건과 무관하게 테이블 전체를 읽는다는 걸 확인.
- `JIT`: 플랜 총 cost가 임계값(`jit_above_cost`, 기본 100000)을 넘으면 필터/튜플 변환
  코드를 네이티브로 컴파일한다. 여기선 컴파일 비용(1.9ms)이 이득 대비 미미한 수준.
- `actual time`(끝값 484.802ms) vs `Execution Time`(594.588ms)의 차이(~110ms)는 실행기
  내부 시간이 아니라 **결과 350만 행을 클라이언트로 직렬화/전송하는 비용**이다
  (`SELECT *`로 대량 행을 가져올 때 무시 못 할 크기가 됨 — 페이지네이션 챕터에서 재등장).

### 2. 베이스라인 — 쿼리 B, 인덱스 없음

```sql
EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345;
```

```
Gather  (cost=1000.00..78202.31 rows=6 width=49) (actual time=682.560..698.692 rows=1 loops=1)
  Workers Planned: 2
  Workers Launched: 2
  ->  Parallel Seq Scan on orders  (cost=0.00..77201.71 rows=2 width=49) (actual time=652.416..652.913 rows=0 loops=3)
        Filter: (customer_id = 12345)
        Rows Removed by Filter: 1666666
Planning Time: 0.069 ms
Execution Time: 698.719 ms
```

**해설**
- `Gather`는 여러 워커가 나눠 처리한 결과를 하나로 모으는 상위 노드. `cost=1000.00..`의
  시작 비용 1000은 `parallel_setup_cost`(워커 프로세스 기동 고정 비용) — 쿼리 A에는 이게
  없었다(병렬화를 아예 안 했으니까).
- `Workers Planned: 2 / Launched: 2` + 리더까지 총 3개 프로세스가 테이블을 나눠 읽는다
  (`loops=3`).
- **함정**: `loops > 1`인 `Parallel Seq Scan` 노드의 `actual time`/`actual rows`는
  **총합이 아니라 루프당 평균**이다. `rows=0`은 "3번 실행 평균이 0.33 → 반올림 표시"일
  뿐, 실제 매치 결과는 상위 `Gather` 노드의 `rows=1`(loops=1, 평균 아님)이 진짜 값.
- `Rows Removed by Filter: 1666666`도 워커당 평균 — `1666666 × 3 ≈ 5,000,000`으로 역시
  테이블 전체를 나눠서 다 읽었다는 뜻.
- **왜 쿼리 A는 병렬화 안 됐는데 쿼리 B는 됐나**: Postgres는 워커가 찾은 행을 리더에게
  전달할 때마다 `parallel_tuple_cost`(기본 0.1)를 추가로 매긴다. 쿼리 A(매치 350만 건)는
  전송 비용만 `350만 × 0.1 = 35만`이라 병렬화 이득을 압도해 기각됐고, 쿼리 B(매치 1건)는
  이 비용이 무시할 만해 병렬 플랜이 채택됐다.
- **핵심 관찰**: 매치 행이 1건뿐인 이 쿼리(698.719ms)가 350만 건 매치되는 쿼리 A
  (594.588ms)보다 오히려 더 오래 걸렸다. 인덱스 없는 Seq Scan은 매치 행 수와 무관하게
  항상 테이블 전체(500만 행)를 읽기 때문 — 실행 시간은 "몇 건을 찾느냐"가 아니라
  "테이블이 얼마나 크냐"에 비례한다.

### 3. 고선택도 컬럼(`customer_id`)에 인덱스 추가 — 쿼리 B 재실행

```sql
CREATE INDEX idx_orders_customer_id ON orders (customer_id);  -- 500만 행 대상, 약 3초 소요

EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345;
```

```
Index Scan using idx_orders_customer_id on orders  (cost=0.43..28.54 rows=6 width=49) (actual time=0.039..0.040 rows=1 loops=1)
  Index Cond: (customer_id = 12345)
Planning Time: 0.214 ms
Execution Time: 0.062 ms
```

**해설**
- `698.719ms → 0.062ms`, 약 **11,270배 개선**. `CREATE INDEX`가 3초 걸린 건 500만 행짜리
  B-tree를 처음부터 빌드하는 비용(챕터 14 "인덱스가 write 성능에 미치는 영향"에서 재등장).
- `cost=0.43..28.54`: 아까 Parallel Seq Scan(1000.00..78202.31)과 비교해 약 2,700배 감소.
  B-tree는 균형 트리라 500만 행이어도 `log₂(5,000,000) ≈ 23`번 비교만으로 대상을 찾는다.
- `Filter` 대신 `Index Cond`로 표시되고 `Rows Removed by Filter` 자체가 사라졌다 — 인덱스가
  조건에 맞는 위치만 찾아서 그 행에만 접근했으므로 애초에 불필요한 행을 하나도 안 읽었다는
  뜻.
- `rows=6`(추정치)은 인덱스 생성 전후로 그대로다 — `customer_id` 컬럼의 카디널리티
  통계(고객 100만 명 / 주문 500만 건 → 고객당 평균 5건)로 계산되는 값이라 인덱스 유무와
  무관하다. 실제는 1건 매치됐으니 추정 오차는 있지만 문제없는 수준.
- `loops=1`, 병렬 워커 없음 — 총 비용(28.54)이 너무 작아 병렬화를 검토조차 안 함.

### 4. 저선택도 컬럼(`status`)에 인덱스 추가 — 대조군, 쿼리 A 재실행

```sql
CREATE INDEX idx_orders_status ON orders (status);

EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'DELIVERED';
```

```
Seq Scan on orders  (cost=0.00..113660.00 rows=3471333 width=49) (actual time=1.673..476.381 rows=3500112 loops=1)
  Filter: ((status)::text = 'DELIVERED'::text)
  Rows Removed by Filter: 1499888
Planning Time: 0.081 ms
JIT:
  Functions: 2
  Options: Inlining false, Optimization false, Expressions true, Deforming true
  Timing: Generation 0.159 ms (Deform 0.059 ms), Inlining 0.000 ms, Optimization 0.149 ms, Emission 1.501 ms, Total 1.809 ms
Execution Time: 586.007 ms
```

**해설**
- `cost(113660.00)`와 플랜(Seq Scan) 모두 인덱스 생성 전(113660.10)과 사실상 동일 —
  옵티마이저가 `idx_orders_status`를 완전히 무시했다.
- 이유: `status='DELIVERED'`가 전체의 70%를 차지하다 보니, 매치되는 행이 테이블 거의
  모든 힙 페이지에 흩어져 있다. 인덱스를 거치나 안 거치나 결국 읽어야 할 힙 페이지
  집합이 거의 같은데, 인덱스 순회라는 추가 비용만 얹히는 셈이라 Seq Scan이 더 싸다고
  정확히 계산된 것.
- `Rows Removed by Filter: 1499888`, `Execution Time` 586.007ms — 베이스라인(594.588ms)과
  오차범위 내로 동일. 인덱스 존재가 실행 계획에 어떤 영향도 못 줬다는 걸 재확인.

### 5. `enable_seqscan = off`로 강제 Bitmap 플랜 — 옵티마이저 선택 검증

`EXPLAIN`만으로는 옵티마이저가 기각한 대안 플랜의 실제 비용을 볼 수 없으므로, 플래너
설정으로 Seq Scan을 강제로 끄고 대안(인덱스 기반) 플랜이 정말 더 느린지 직접 비교했다.

```sql
SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'DELIVERED';

RESET enable_seqscan;  -- 세션 단위 설정이라 확인 후 반드시 원복
```

```
Bitmap Heap Scan on orders  (cost=38839.26..133390.93 rows=3471333 width=49) (actual time=265.976..1076.134 rows=3500112 loops=1)
  Recheck Cond: ((status)::text = 'DELIVERED'::text)
  Heap Blocks: exact=51134
  ->  Bitmap Index Scan on idx_orders_status  (cost=0.00..37971.43 rows=3471333 width=0) (actual time=257.304..257.304 rows=3500112 loops=1)
        Index Cond: ((status)::text = 'DELIVERED'::text)
Planning Time: 0.076 ms
JIT:
  Functions: 2
  Options: Inlining false, Optimization false, Expressions true, Deforming true
  Timing: Generation 0.143 ms (Deform 0.049 ms), Inlining 0.000 ms, Optimization 0.000 ms, Emission 0.000 ms, Total 0.143 ms
Execution Time: 1185.965 ms
```

**해설**
- **Execution Time 1185.965ms — Seq Scan(586.007ms)보다 약 2배 느림.** 옵티마이저의
  원래 선택(Seq Scan)이 실제로 더 빠른 선택이었음을 실측으로 확인했다. 플래너 자신의
  비용 모델(Bitmap `cost` 38839.26..133390.93 vs Seq Scan `cost` 0.00..113660.00)이 이미
  이 결과를 정확히 예측하고 있었다.
- `Bitmap Heap Scan`은 Index Scan과 Seq Scan 사이의 중간 전략, 2단계로 동작한다:
  1. **Bitmap Index Scan** — 인덱스를 스캔해 매치 행을 즉시 가져오지 않고 "매치 행이
     있는 힙 페이지" 비트맵을 메모리에 만든다. `actual time=257.304..257.304`처럼
     시작/종료 시각이 같은 이유는 비트맵이 부분적으로 스트리밍될 수 없고, 전부 완성된
     뒤에야 다음 단계로 넘어가기 때문.
  2. **Bitmap Heap Scan** — 비트맵에 표시된 페이지를 인덱스가 가리키는 순서(랜덤)가
     아니라 **물리적 순서대로** 읽어 랜덤 I/O를 줄인다.
- `Heap Blocks: exact=51134`: 비트맵이 `work_mem`에 다 들어가 행 단위까지 정확했다는
  뜻(안 들어가면 페이지 단위로만 대략(`lossy`) 표시되고 `Recheck Cond`가 실질적인
  재필터링을 수행하게 된다). 51,134개 페이지 — 테이블 대부분 — 를 읽어야 했으므로
  애초에 인덱스로 얻을 이점이 없었다.

## 시행착오 / Q&A

**Q. `Parallel Seq Scan`의 `actual rows=0, loops=3`을 보고 "매치된 게 없나?" 했는데?**
A. `loops > 1`인 노드의 `actual time`/`actual rows`는 **총합이 아니라 루프당 평균**이다.
`rows=0`은 "3번 실행 평균이 0.33 → 반올림 표시"일 뿐, 실제 결과는 상위 `Gather` 노드의
`rows=1`(loops=1, 평균 아님)이 진짜 값이다. 병렬 플랜을 읽을 땐 항상 최상위 `Gather`
노드의 값을 최종 결과로 봐야 한다.

**Q. 인덱스를 만들었는데 왜 옵티마이저가 안 쓰나?**
A. 버그가 아니라 비용 기반 최적화의 정상 동작. `EXPLAIN`으로는 옵티마이저가 기각한
대안 플랜을 볼 수 없으므로, 정말 인덱스가 더 느린지 확인하려면 `enable_seqscan = off`
같은 플래너 설정으로 강제 비교해야 한다(세션 단위 설정이라 확인 후 `RESET` 필수).

## 최종 구성

| 인덱스 | 대상 컬럼 | 선택도 | 옵티마이저 사용 여부 | 처리 |
|---|---|---|---|---|
| `idx_orders_customer_id` | `customer_id` | 높음 | 사용함 (Index Scan, 11,270배 개선) | 유지, `db/schema.sql`에 반영 |
| `idx_orders_status` | `status` | 낮음 (70%) | 사용 안 함 (여전히 Seq Scan) | `DROP INDEX`로 제거 |

## ADR

### Decision
- 단일 컬럼 인덱스는 선택도가 충분히 높은 컬럼(`customer_id`류: FK, 소수 매치)에만
  효과가 있고, 선택도가 낮은 컬럼(`status`류: 값 몇 개가 테이블 상당 비율을 차지)에는
  효과가 없다는 것을 실측으로 확인 — 이후 챕터(복합 인덱스, 커버링 인덱스)에서 이
  선택도 기준을 계속 적용한다.

### Drivers
- 옵티마이저는 비용 모델(디스크 접근, 튜플 처리, 병렬 전송 비용)로 플랜을 선택하며,
  "인덱스가 있으면 무조건 쓴다"는 가정은 틀렸다는 걸 직접 확인할 필요가 있었음

### Alternatives considered
- (해당 없음 — 이번 챕터는 관찰/실험 위주)

### Consequences
- `idx_orders_status`는 현재 쿼리 패턴에서 옵티마이저가 절대 선택하지 않는 "죽은
  인덱스"였다(그대로 두면 매 INSERT/UPDATE마다 유지 비용만 발생 — 챕터 14에서 다룰
  주제). `DROP INDEX`로 제거하기로 결정.
- `idx_orders_customer_id`는 FK 컬럼 인덱스로 실무에서도 일반적으로 유용해 유지하고
  `db/schema.sql`에 반영하기로 결정. 스키마를 처음부터 재적용해도 자동으로 생성된다.

### Follow-ups
- (해결됨) `idx_orders_customer_id` → `db/schema.sql`에 반영
- (해결됨) `idx_orders_status` → `DROP INDEX idx_orders_status;`로 제거
- 챕터 4: 복합 인덱스 설계 — 컬럼 순서에 따른 효과 차이
