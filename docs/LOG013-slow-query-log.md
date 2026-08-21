# LOG013 — 슬로우 쿼리 로그 설정 및 분석

## 배경 / 목표

Phase 4(운영 관점) 챕터 13. 지금까지는 `EXPLAIN ANALYZE`로 쿼리 하나하나를 직접
찍어봤지만, 실제 운영에서는 "지금 어떤 쿼리가 느린가/부담을 주는가"를 미리 알 수
없다. Postgres가 제공하는 두 가지 운영 도구 — **슬로우 쿼리 로그**(개별 쿼리 단위
사후 확인)와 **`pg_stat_statements`**(쿼리 패턴별 누적 통계) — 를 설정하고
실제로 사용해본다.

## 개념

### `log_min_duration_statement` — 개별 슬로우 쿼리 로그
이 값(ms) 이상 걸린 쿼리를 로그에 남긴다. `0`이면 모든 쿼리, `-1`이면
비활성화(기본값). 운영에서는 보통 100~1000ms 같은 임계값을 쓴다. 이 설정은
**재시작 없이 반영 가능**하다(`SIGHUP`으로 리로드되는 파라미터) —
`ALTER SYSTEM SET ...` 후 `SELECT pg_reload_conf();`만 하면 된다. Postgres
로그는 기본적으로 stderr로 나가는데, Docker 컨테이너 안에서 실행 중이라
`docker logs`로 바로 볼 수 있다.

### `pg_stat_statements` — 쿼리 패턴별 누적 통계
Postgres 공식 배포판에 기본 포함된 **contrib 확장**이다(서드파티 애드온이
아니라 Postgres 프로젝트가 직접 만들고 유지보수). 별도 설치 없이 표준
`postgres` 이미지 안에 이미 바이너리가 들어있어서 설정 활성화 + `CREATE
EXTENSION`만으로 쓸 수 있다.

로그와 다르게 이건 **쿼리를 정규화(파라미터를 `$1`, `$2`로 치환)해서 자동
집계**한다 — `category.id=36`이든 `category.id=48`이든 같은 쿼리 모양이면 하나의
통계 행(`calls`, `total_exec_time`, `mean_exec_time`, `rows` 등)으로 합쳐진다.
운영에서 진짜 문제가 되는 건 "가장 느린 쿼리 1개"가 아니라 "누적으로 DB를 가장
많이 잡아먹는 쿼리 패턴"인 경우가 많은데, `total_exec_time` 기준 정렬이 정확히
그걸 찾아준다(자주 호출되는 쿼리는 개별로는 안 느려도 누적으로는 1위가 될 수
있음).

`shared_preload_libraries`를 바꿔야 해서 **컨테이너/서버 재시작이 필요**하다
(`log_min_duration_statement`와 달리 프로세스 시작 시점에 로드되는 모듈이라서).

## 진행 내용

### 1. `log_min_duration_statement` 설정 및 검증

```sql
ALTER SYSTEM SET log_min_duration_statement = '200ms';
SELECT pg_reload_conf();
```

`SELECT pg_sleep(0.3);`로 확실하게 300ms 걸리는 쿼리를 날려서 확인:

```
2026-08-20 22:54:50.056 UTC [1] LOG:  received SIGHUP, reloading configuration files
2026-08-20 22:54:50.060 UTC [1] LOG:  parameter "log_min_duration_statement" changed to "200ms"
2026-08-20 22:55:08.413 UTC [70] LOG:  duration: 305.319 ms  execute <unnamed>: SELECT pg_sleep(0.3)
```

임계값(200ms)을 넘어서 정확히 잡혔다.

실제 데이터로도 확인해보려고 `SELECT * FROM orders WHERE ordered_at::text LIKE
'%2025-06%';`(컬럼에 함수를 씌워 인덱스를 못 타게 강제한 쿼리)를 돌렸는데, 이땐
로그에 안 잡혔다. 버퍼 캐시가 뜨거워서(계속 반복 조회해온 테이블이라) 실제로
200ms 안에 끝났을 가능성이 높다고 판단해, 같은 쿼리를 `EXPLAIN ANALYZE`로
재실행해서 검증:

```
2026-08-20 22:57:11.939 UTC [2896] LOG:  duration: 1227.276 ms  statement: EXPLAIN ANALYZE SELECT * FROM orders WHERE ordered_at::text LIKE '%2025-06%';
```

이번엔 1227.276ms로 잡혔다 — 메커니즘 자체는 정상이고, 캐시 상태에 따라 같은
쿼리도 로그에 잡히거나 안 잡힐 수 있다는 걸 확인. 슬로우 쿼리 로그는 "이 쿼리가
구조적으로 느리다"보다 "이번 실행이 느렸다"를 알려주는 도구라는 걸 체감한 계기.

### 2. `pg_stat_statements` 설정

```sql
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
```
```bash
docker restart practice-db-performance-postgres-1
```
```sql
CREATE EXTENSION pg_stat_statements;
```

### 3. 결과 조회 및 분석

```sql
SELECT query, calls, round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

상위 결과:

| 순위 | 쿼리 요약 | calls | total_ms | mean_ms | rows |
|---|---|---|---|---|---|
| 1 | LOG009의 `.distinct()` 카테고리 필터 쿼리 (`orders JOIN order_items/products/categories`, `c1_0.id=$1`) | 4 | 2317.07 | 579.27 | 80 |
| 2 | LOG009/010의 `EXISTS` 카테고리 필터 쿼리 | 1 | 129.38 | 129.38 | 20 |
| 3~10 | `CREATE EXTENSION`, `pg_extension`/`pg_cast`/`pg_am` 조회 등 | 각 1 | 0.3~60 | - | - |

**해설**
- **1위 쿼리는 단일 실행 기준(579ms)으로는 최상위가 아니지만, 4번 호출되면서
  누적 2317ms로 전체 1위**가 됐다 — 이게 `pg_stat_statements`의 진짜 가치다.
  개별 로그 라인을 일일이 세는 대신 "이 쿼리 패턴이 총 몇 번, 얼마나 걸렸는가"를
  자동 집계해서 보여준다.
- 3위 이하는 대부분 **노이즈**다 — IntelliJ DB 콘솔이 메타데이터를 가져오려고
  내부적으로 날린 `pg_catalog` 조회들. 운영에서는 이런 도구성 쿼리를 걸러내고
  애플리케이션 쿼리만 봐야 한다.

### 4. 노이즈 제거 — 리셋이 필터링보다 간단하다

```sql
SELECT pg_stat_statements_reset();
-- 이제부터 측정하려는 쿼리들만 실행
-- 그다음 조회하면 그 사이에 실행된 것만 보임
```

측정 직전에 카운터를 리셋하면 과거 이력(IDE 메타데이터 쿼리 등)이 다 지워지고
리셋 이후 실행한 것만 깨끗하게 남는다 — 운영에서도 "이 배포 이후부터의 통계만
보고 싶다" 같은 상황에 흔히 쓰는 방법. 복잡한 `WHERE query NOT ILIKE '%pg_%'`
같은 패턴 필터링보다 훨씬 간단하고 확실하다.

## 다른 주요 DB는 어떻게 하나

"느린 쿼리 로그"와 "누적 통계" 두 축으로 비교하면 개념은 대부분 비슷하다.

| DB | 느린 쿼리 로그 (`log_min_duration_statement`에 대응) | 누적 통계 (`pg_stat_statements`에 대응) |
|---|---|---|
| **MySQL** | `slow_query_log` + `long_query_time`(초 단위, 기본 10초) — 파일/테이블 기록 | `performance_schema`의 `events_statements_summary_by_digest` — 쿼리를 정규화("digest")해서 자동 집계, 기본 내장 |
| **Oracle** | SQL Trace / TKPROF (세션 단위 상세 추적) | `V$SQL`, `V$SQLAREA`(캐시된 SQL 실행 통계, 무료) / AWR(장기 추이, 유료 라이선스 필요) |
| **SQL Server** | Extended Events(구 SQL Profiler) | **Query Store** — SQL Server 2016+ 내장, 쿼리 텍스트+실행계획+실행 통계를 시계열로 자동 저장(플랜 회귀 탐지까지 지원) / `sys.dm_exec_query_stats`(더 가벼운 DMV) |
| **MongoDB**(참고, NoSQL) | `db.setProfilingLevel()` + `slowms` 임계값 | `db.currentOp()`(실시간), Atlas는 자체 Performance Advisor 제공 |

`pg_stat_statements`는 MySQL의 `performance_schema` 방식과 개념적으로 가장
유사하다(둘 다 무료·기본 내장, 파라미터 정규화). Oracle/SQL Server의 고급
기능(AWR, Query Store)은 시계열 추이나 실행계획 변화 추적까지 더 깊이 들어간다는
차이가 있다.

## 시행착오 / Q&A

**Q. `pg_stat_statements`는 Postgres의 기본 기능인가?**
A. 그렇다 — Postgres 공식 배포판에 포함된 contrib 확장이라, 서드파티 애드온을
따로 설치할 필요가 없다. 표준 이미지 안에 이미 바이너리가 들어있어서 설정
활성화만으로 쓸 수 있다.

**Q. 매니지드 Postgres(AWS RDS, GCP Cloud SQL, Supabase 등)에서도 이 뷰를
직접 조회하나?**
A. 그렇다 — `pg_stat_statements`는 일반 SQL 뷰라, 접속해서 `SELECT * FROM
pg_stat_statements ...`로 직접 조회하는 게 기본이다. 다른 점은
`shared_preload_libraries` 같은 설정을 직접 `postgresql.conf`로 못 만지고
각 서비스의 파라미터 그룹/플래그 UI로 바꾸며, 재시작도 그쪽에서 처리해준다는
것. 상당수 매니지드 서비스는 이 확장을 기본으로 이미 켜둔 채로 제공한다. 일부는
이 데이터를 가공한 대시보드 UI도 따로 제공하지만(Supabase의 "Query Performance"
페이지 등), 밑바닥은 결국 같은 뷰다.

**Q. `log_min_duration_statement`는 재시작 없이 되는데 왜
`shared_preload_libraries`는 재시작이 필요한가?**
A. 전자는 매 쿼리 실행 시점에 참조하는 단순 설정값이라 `SIGHUP`(설정 파일
리로드)만으로 충분하다. 후자는 **프로세스가 시작될 때 공유 메모리 구조를 미리
할당**해야 하는 모듈이라(통계를 저장할 공간 자체를 시작 시점에 만들어둬야 함),
런타임에 끼워 넣을 수 없다 — 재시작이 필수다.

## 최종 구성

이번 챕터는 스키마가 아니라 **런타임 DB 설정**을 다뤘다 — `db/schema.sql`이나
애플리케이션 코드 변경 없음.

| 설정 | 값 | 적용 방식 |
|---|---|---|
| `log_min_duration_statement` | `200ms` | `ALTER SYSTEM` + `pg_reload_conf()` (재시작 불필요) |
| `shared_preload_libraries` | `pg_stat_statements` | `ALTER SYSTEM` + 컨테이너 재시작 |
| `pg_stat_statements` 확장 | 활성화 | `CREATE EXTENSION` |

이 설정들은 `postgresql.auto.conf`(데이터 볼륨 안)에 저장돼 컨테이너를 재시작해도
유지되지만, **볼륨을 통째로 지우고 새로 만들면 초기화된다** — 재현성이 필요하면
`compose.yaml`의 `command`에 `-c shared_preload_libraries=pg_stat_statements`
같은 인자를 추가하는 방법도 있으나, 이번 챕터에서는 그렇게까지는 하지 않음(운영
관점 학습이 목적이라 매번 재현 가능하게 만드는 것보다 지금 상태로 계속 실습하는
쪽을 택함).

## ADR

### Decision
- 슬로우 쿼리 로그(`log_min_duration_statement`)는 "이번 실행이 느렸는지"
  사후 확인용, `pg_stat_statements`는 "어떤 쿼리 패턴이 전체 부하에 가장
  기여하는지" 파악하는 주력 도구로 역할을 나눠서 이해한다.

### Drivers
- `EXPLAIN ANALYZE`로 쿼리 하나하나를 확인하는 지금까지의 방식은 "무엇을
  봐야 할지 이미 아는 상태"를 전제로 한다 — 운영에서는 "무엇이 문제인지 모르는
  상태"에서 시작해야 하므로 별도의 발견(discovery) 도구가 필요했음

### Alternatives considered
- (해당 없음 — 이번 챕터는 Postgres 표준 도구 설정/사용법 학습 위주)

### Consequences
- `pg_stat_statements`는 쿼리 텍스트와 통계를 서버 메모리(및 선택적으로
  디스크)에 계속 쌓아두므로, 아주 다양한 쿼리 패턴이 많은 운영 환경에서는
  메모리 사용량(`pg_stat_statements.max` 설정)을 신경 써야 한다 — 이번
  학습 환경 규모에서는 해당 없음
- 로그 레벨 설정이 런타임 DB 설정이라 `db/schema.sql`에 반영되지 않음 —
  향후 이 프로젝트를 처음부터 다시 세팅하는 사람은 이 챕터의 설정을 수동으로
  다시 적용해야 함

### Follow-ups
- 챕터 14 — 인덱스가 write 성능에 미치는 영향
