# LOG015 — VACUUM, ANALYZE

## 배경 / 목표

Phase 4 챕터 15. Postgres의 MVCC가 만들어내는 dead tuple을 직접 발생시켜
`VACUUM`의 효과를 확인하고, `ANALYZE`가 실제로 만드는 옵티마이저 통계를
들여다본다. 마지막으로 챕터 10에서 예고했던 "Index Only Scan이 힙을
건너뛰려면 visibility map이 최신이어야 한다"를 실측으로 마무리한다.

## 개념

### MVCC와 dead tuple
Postgres는 MVCC(다중 버전 동시성 제어) 방식이라, `UPDATE`/`DELETE`가 기존 행을
그 자리에서 덮어쓰거나 지우지 않는다 — **새 버전을 추가하고 옛 버전은 "죽은
튜플"(dead tuple)로 표시만** 한다(다른 트랜잭션이 여전히 그 옛 버전을 봐야 할
수도 있어서, 락 없이 일관된 스냅샷을 주기 위한 대가).

### `VACUUM`
더 이상 아무도 안 보는 dead tuple을 정리해서 공간을 재사용 가능하게 만든다.
동시에 **visibility map**(각 힙 페이지에 "이 페이지의 모든 튜플이 전부
보이는 상태인가"를 표시해두는 자료구조)도 갱신한다.

### `ANALYZE`
테이블 데이터를 샘플링해서 옵티마이저 통계(`pg_stats`) — 행 수, 컬럼별 최빈값
(MCV)과 빈도, distinct 값 개수 등 — 를 최신 상태로 유지한다. Phase 1~3 내내
봐온 "옵티마이저의 정확한 추정치"가 전부 이 통계에서 나온다.

### `autovacuum`
`VACUUM`/`ANALYZE`를 백그라운드에서 자동 실행하는 데몬. 기본적으로 켜져
있다. `VACUUM`이 트리거되는 기본 공식:

```
임계값 = autovacuum_vacuum_threshold(기본 50) + autovacuum_vacuum_scale_factor(기본 0.2) × 예상 행 수
```

500만 행 테이블이면 임계값이 약 100만 건이다 — **테이블이 클수록 dead tuple이
꽤 많이 쌓여야 자동으로 청소된다**는 뜻.

### Visibility map과 Index Only Scan
Index Only Scan이 힙을 건너뛰려면, 인덱스에 필요한 컬럼이 다 있는 것만으로는
부족하다 — 그 행이 들어있는 힙 페이지가 visibility map에 "전부 보임(all
visible)"으로 표시돼 있어야 한다. `UPDATE`/`DELETE`로 페이지가 변경되면 그
표시가 지워지고, 다음 `VACUUM`이 다시 표시해줄 때까지 Index Only Scan도
힙에 들러 가시성을 직접 확인해야 한다(`Heap Fetches`로 표시됨).

## 진행 내용

### 1. Dead tuple 만들기

시작 시점 확인:
```sql
SELECT relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables WHERE relname = 'orders';
```
```
n_live_tup=5000008, n_dead_tup=0, last_autovacuum=2026-08-20 01:31:44, last_autoanalyze=2026-08-20 01:31:45
```

10만 건 UPDATE로 dead tuple 발생:
```sql
UPDATE orders SET updated_at = now() WHERE id <= 100000;
-- 100,000 rows affected in 17s 295ms
```

재확인:
```
n_live_tup=5000008, n_dead_tup=100000, last_autovacuum=(변화 없음)
```

**해설**: `n_dead_tup`이 정확히 10만 늘었다. `last_autovacuum`은 그대로다 —
10만 건은 앞서 계산한 임계값(약 100만 건)의 1/10밖에 안 돼서 autovacuum이
아직 안 돈 것. 큰 테이블일수록 이 절대 임계값도 커진다는 걸 직접 확인.

### 2. 수동 `VACUUM`

```sql
VACUUM VERBOSE orders;
```

이후 재확인 결과 `n_dead_tup=0`으로 정리됐고, `n_live_tup`도 살짝 변했다.

**해설**: `n_live_tup`/`n_dead_tup`은 통계 수집기가 매 INSERT/UPDATE/DELETE
이벤트를 누적 보고받아 유지하는 **추정치**라 시간이 지나면 조금씩 어긋날 수
있다. `VACUUM`은 테이블을 실제로 전체 스캔하기 때문에, 끝난 뒤 그 결과로
`n_live_tup`을 더 정확한 값으로 보정한다 — 행이 사라진 게 아니라 추정치가
실측치로 교정된 것. `VACUUM`은 절대 보이는(살아있는) 행을 지우지 않는다.

### 3. `ANALYZE`가 만드는 통계 확인

```sql
SELECT attname, n_distinct, most_common_vals, most_common_freqs, null_frac
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';
```
```
most_common_vals:  {DELIVERED,SHIPPED,CANCELLED,PROCESSING,REFUNDED}
most_common_freqs: {0.694266676902771,0.09963333606719971,0.07953333109617233,0.07460000365972519,0.05196666717529297}
```

**해설**: LOG002에서 시드 생성 시 목표했던 분포(DELIVERED 70% / SHIPPED 10% /
CANCELLED 8% / PROCESSING 7% / REFUNDED 5%)와 거의 정확히 일치한다(69.4% /
9.96% / 7.95% / 7.46% / 5.2%). 챕터 3에서 "옵티마이저가 정확하게 추정했다"고
했던 근거가 바로 이 `most_common_vals`/`most_common_freqs`였다는 게 확인됐다.

### 4. Visibility map과 Index Only Scan — 3단계 대조

**(1) 초기 상태:**
```sql
EXPLAIN ANALYZE SELECT status FROM orders WHERE ordered_at > '2025-12-01';
```
```
Index Only Scan using idx_orders_ordered_at_covering_status on orders (actual rows=211689 loops=1)
  Heap Fetches: 4238
Execution Time: 78.024 ms
```

**(2) 이 범위를 UPDATE해서 visibility map을 오염시킴:**
```sql
UPDATE orders SET updated_at = now() WHERE ordered_at > '2025-12-01';
```
같은 쿼리 재실행:
```
Index Only Scan using idx_orders_ordered_at_covering_status on orders (actual rows=211689 loops=1)
  Heap Fetches: 422045
Execution Time: 2869.664 ms
```

**(3) `VACUUM` 후 재확인:**
```sql
VACUUM orders;
```
```
Index Only Scan using idx_orders_ordered_at_covering_status on orders (actual rows=211689 loops=1)
  Heap Fetches: 0
Execution Time: 55.472 ms
```

**해설**
- 초기 상태에도 `Heap Fetches: 4238`이 남아있었다 — 앞서 1번 실습의 UPDATE(`id
  <= 100000`)가 이 범위와 일부 겹쳤을 가능성이 높다.
- UPDATE로 범위 전체를 오염시키자 `Heap Fetches`가 422,045까지 치솟았고,
  **`Execution Time`이 78ms → 2870ms로 약 36.8배 느려졌다.**
- `VACUUM` 후 `Heap Fetches: 0`으로 완전히 회복, 55.472ms로 돌아왔다.
- **완전히 오염된 상태(2870ms)와 깨끗한 상태(55ms)를 직접 비교하면 약
  52배 차이.** "인덱스에 필요한 컬럼이 다 있으면 무조건 Index Only Scan이
  빠르다"가 아니라, **visibility map이 최신이어야 그 이점을 실제로 누릴 수
  있다**는 게 정량적으로 확인됐다 — `VACUUM`이 단순히 공간 청소만 하는 게
  아니라 읽기 성능에도 직결된다는 것.

## 시행착오 / Q&A

**Q. `VACUUM` 후 `n_live_tup`이 줄어든 것처럼 보였는데 데이터가 사라진 건가?**
A. 아니다. `pg_stat_user_tables`의 `n_live_tup`은 통계 수집기가 이벤트
기반으로 누적한 추정치라 실제 값과 미세하게 어긋날 수 있고, `VACUUM`의 전체
스캔 결과로 더 정확한 값으로 보정되면서 살짝 바뀐 것뿐이다. 걱정되면
`SELECT COUNT(*)`로 직접 확인 가능(느리지만 정확 — 챕터 12에서 배운 그대로).

## 최종 구성

이번 챕터는 스키마/코드 변경이 아니라 **운영 동작 관찰**이 목적이었다.
`orders` 테이블에 대해 실제로 `UPDATE`(총 30만 건 이상, `updated_at`만
변경) → `VACUUM`을 두 차례 수행했으나, `VACUUM`은 데이터를 변경하지 않는
안전한 유지보수 작업이라 테이블 내용에는 영향이 없다.

## ADR

### Decision
- 대량 `UPDATE`/`DELETE` 이후에는 (autovacuum이 알아서 처리하겠지만) 그 타이밍이
  테이블 크기에 따라 상당히 늦어질 수 있다는 걸 인지하고, 성능이 중요한
  구간에서는 수동 `VACUUM`을 고려한다.

### Drivers
- Index Only Scan이 챕터 10~12에서 만들어낸 성능 이득이 "visibility map이
  깨끗하다"는 전제 위에 있었다는 걸 직접 검증할 필요가 있었음(그 전제가
  깨지면 최대 50배 이상 성능이 되돌아갈 수 있음을 확인)

### Alternatives considered
- (해당 없음 — 이번 챕터는 Postgres 표준 유지보수 도구의 동작 원리 학습 위주)

### Consequences
- autovacuum 기본 설정(`scale_factor=0.2`)은 큰 테이블에서 dead tuple이
  꽤 쌓일 때까지 기다린다 — write가 잦고 read 성능(특히 Index Only Scan)이
  중요한 대형 테이블은 `autovacuum_vacuum_scale_factor`를 테이블별로 낮게
  설정하는 튜닝이 실무에서 흔히 쓰인다(이번 챕터에서 직접 적용하지는 않음)
- `pg_stats`가 정확할수록 옵티마이저 추정도 정확해진다 — 대량 데이터 변경
  후에는 `ANALYZE`도 함께 고려해야 함(자동으로 돌긴 하지만 `VACUUM`과 마찬가지로
  타이밍 이슈가 있음)

### Follow-ups
- 챕터 16(마지막) — 파티셔닝 (orders, 날짜 기준)
