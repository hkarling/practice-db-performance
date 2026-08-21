-- ============================================================================
-- practice-db-performance 학습 과정에서 실제로 실행한 쿼리 모음
-- ============================================================================
-- 각 섹션은 docs/LOG0##-*.md 문서와 1:1로 대응한다. 순서대로 실행하도록 만든
-- 스크립트가 아니라 "그 시점에 무엇을 돌려봤는지"를 남겨둔 기록이다 —
-- 인덱스를 만들었다가 지우고 다시 다른 순서로 만드는 실험적인 흐름이 그대로
-- 포함돼 있으니, 재현하려면 각 LOG 문서의 맥락과 함께 읽을 것.
--
-- 전제: db/schema.sql이 이미 적용되고 seed/ 데이터가 적재된 로컬 Postgres.
-- ============================================================================


-- ============================================================================
-- Phase 1 — 실행 계획 읽기
-- ============================================================================

-- ---- 챕터 1~3: EXPLAIN ANALYZE 기본 / 슬로우 쿼리 재현 / 단일 컬럼 인덱스 (LOG003) ----

EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'DELIVERED';

EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345;

CREATE INDEX idx_orders_customer_id ON orders (customer_id);

CREATE INDEX idx_orders_status ON orders (status);

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'DELIVERED';

RESET enable_seqscan;  -- 세션 설정 원복 필수

DROP INDEX idx_orders_status;  -- 선택도가 낮아 옵티마이저가 안 써서 정리


-- ---- 챕터 4: 복합 인덱스 설계 — 컬럼 순서 (LOG004) ----

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE customer_id = 12345
ORDER BY ordered_at DESC
LIMIT 10;

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'DELIVERED'
ORDER BY ordered_at DESC
LIMIT 20;

CREATE INDEX idx_orders_status_ordered_at ON orders (status, ordered_at DESC);

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'REFUNDED'
ORDER BY ordered_at DESC
LIMIT 20;

-- 컬럼 순서를 반대로 한 대조군 실험 (실험 후 원래대로 복구)
DROP INDEX idx_orders_status_ordered_at;
CREATE INDEX idx_orders_ordered_at_status ON orders (ordered_at DESC, status);

DROP INDEX idx_orders_ordered_at_status;
CREATE INDEX idx_orders_status_ordered_at ON orders (status, ordered_at DESC);


-- ============================================================================
-- Phase 2 — JPA/ORM 레벨 문제 (챕터 5~8)
-- ============================================================================
-- 이 구간은 순수 SQL보다 JPQL(@Query)/QueryDSL 코드와 Hibernate가 생성한 SQL
-- 로그 위주라 별도 실행 스크립트가 없다 — docs/LOG005~LOG008 참고.


-- ============================================================================
-- Phase 3 — 복잡한 조회 최적화
-- ============================================================================

-- ---- 챕터 9: 다중 조건 필터링 + JOIN fan-out (LOG009) ----

-- .distinct() 버전 (Hibernate가 생성한 SQL)
EXPLAIN ANALYZE
SELECT DISTINCT o1_0.id, o1_0.created_at, o1_0.customer_id, o1_0.ordered_at, o1_0.status, o1_0.updated_at
FROM orders o1_0
    JOIN order_items oi1_0 ON oi1_0.order_id = o1_0.id
    JOIN products p1_0 ON p1_0.id = oi1_0.product_id
    JOIN categories c1_0 ON c1_0.id = p1_0.category_id
WHERE c1_0.id = 36
ORDER BY o1_0.id DESC
OFFSET 25 ROWS FETCH FIRST 20 ROWS ONLY;

-- EXISTS 버전 (최종 채택, Hibernate가 생성한 SQL)
EXPLAIN ANALYZE
SELECT o1_0.id, o1_0.created_at, o1_0.customer_id, c1_0.id, c1_0.city, c1_0.created_at, c1_0.email,
       c1_0.name, c1_0.state, c1_0.updated_at, c1_0.zip_code, o1_0.ordered_at, o1_0.status, o1_0.updated_at
FROM orders o1_0
    JOIN customers c1_0 ON c1_0.id = o1_0.customer_id
WHERE EXISTS (
    SELECT 1 FROM order_items oi1_0
        JOIN products p1_0 ON p1_0.id = oi1_0.product_id
    WHERE oi1_0.order_id = o1_0.id AND p1_0.category_id = 36
)
ORDER BY o1_0.id DESC
OFFSET 0 ROWS FETCH FIRST 20 ROWS ONLY;

CREATE INDEX idx_order_items_product_id ON order_items (product_id);  -- 챕터 10에서 커버링 버전으로 교체됨


-- ---- 챕터 10: 커버링 인덱스 (LOG010) ----

CREATE INDEX idx_order_items_product_id_covering ON order_items (product_id) INCLUDE (order_id);

DROP INDEX idx_order_items_product_id;  -- 커버링 버전이 완전 상위 호환이라 정리


-- ---- 챕터 11: 대용량 페이지네이션 (LOG011) ----

-- OFFSET 방식
SELECT * FROM orders ORDER BY id DESC OFFSET 4900000 LIMIT 20;
-- 커서 방식 (마지막으로 본 id가 100000이라면)
SELECT * FROM orders WHERE id < 100000 ORDER BY id DESC LIMIT 20;

EXPLAIN ANALYZE
SELECT * FROM orders ORDER BY id DESC OFFSET 0 LIMIT 20;

EXPLAIN ANALYZE
SELECT * FROM orders ORDER BY id DESC OFFSET 4900000 LIMIT 20;

EXPLAIN ANALYZE
SELECT * FROM orders WHERE id < 100000 ORDER BY id DESC LIMIT 20;


-- ---- 챕터 12: 집계 쿼리 최적화 (LOG012) ----

EXPLAIN ANALYZE
SELECT COUNT(*) FROM orders;

EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders GROUP BY status;

-- 잘못된 시도: created_at은 시드 적재 시점이라 선택도가 없고, 이 인덱스에도 없는 컬럼
EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders WHERE created_at > '2023-01-01' GROUP BY status;

-- 올바른 컬럼(ordered_at)이지만 idx_orders_status_ordered_at은 순서가 안 맞아 여전히 미사용
EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders WHERE ordered_at > '2025-12-01' GROUP BY status;

CREATE INDEX idx_orders_ordered_at_covering_status ON orders (ordered_at) INCLUDE (status);

EXPLAIN ANALYZE
SELECT status, COUNT(*) FROM orders WHERE ordered_at > '2025-12-01' GROUP BY status;


-- ============================================================================
-- Phase 4 — 운영 관점
-- ============================================================================

-- ---- 챕터 13: 슬로우 쿼리 로그 (LOG013) ----

ALTER SYSTEM SET log_min_duration_statement = '200ms';
SELECT pg_reload_conf();

SELECT pg_sleep(0.3);

SELECT * FROM orders WHERE ordered_at::text LIKE '%2025-06%';

ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
-- 이 시점에 컨테이너 재시작 필요:
--   docker restart practice-db-performance-postgres-1

CREATE EXTENSION pg_stat_statements;

SELECT query, calls, round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- 노이즈 없이 다시 측정하고 싶을 때
SELECT pg_stat_statements_reset();


-- ---- 챕터 14: 인덱스가 write 성능에 미치는 영향 (LOG014) ----
-- orders를 건드리지 않는 격리된 스크래치 테이블로 실험, 끝나면 DROP.

CREATE TABLE orders_write_test (LIKE orders INCLUDING DEFAULTS INCLUDING IDENTITY);

-- 0단계: 인덱스 없음
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;

-- 1단계: PK 추가
TRUNCATE orders_write_test;
ALTER TABLE orders_write_test ADD PRIMARY KEY (id);
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;

-- 2단계: customer_id 인덱스 추가
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_customer_id ON orders_write_test (customer_id);
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;

-- 3단계: status,ordered_at 복합 인덱스 추가
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_status_ordered_at ON orders_write_test (status, ordered_at DESC);
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;

-- 4단계: ordered_at 커버링 인덱스 추가 (실제 orders와 동일 구성, 총 4개)
TRUNCATE orders_write_test;
CREATE INDEX idx_wt_ordered_at_covering_status ON orders_write_test (ordered_at) INCLUDE (status);
INSERT INTO orders_write_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders LIMIT 500000;

DROP TABLE orders_write_test;  -- 정리


-- ---- 챕터 15: VACUUM, ANALYZE (LOG015) ----

UPDATE orders SET updated_at = now() WHERE id <= 100000;

SELECT relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'orders';

VACUUM VERBOSE orders;

SELECT COUNT(*) FROM orders;

SELECT attname, n_distinct, most_common_vals, most_common_freqs, null_frac
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';

-- visibility map / Index Only Scan 3단계 대조
EXPLAIN ANALYZE SELECT status FROM orders WHERE ordered_at > '2025-12-01';

UPDATE orders SET updated_at = now() WHERE ordered_at > '2025-12-01';

EXPLAIN ANALYZE SELECT status FROM orders WHERE ordered_at > '2025-12-01';

VACUUM orders;
EXPLAIN ANALYZE SELECT status FROM orders WHERE ordered_at > '2025-12-01';


-- ---- 챕터 16: 파티셔닝 (LOG016) ----
-- orders를 건드리지 않는 격리된 스크래치 파티션 테이블로 실험, 끝나면 DROP.

CREATE TABLE orders_partition_test (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    customer_id BIGINT      NOT NULL,
    status      VARCHAR(20) NOT NULL,
    ordered_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (id, ordered_at)  -- 파티션 키가 유니크 제약에 포함돼야 함
) PARTITION BY RANGE (ordered_at);

CREATE TABLE orders_partition_test_2024 PARTITION OF orders_partition_test
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE orders_partition_test_2025 PARTITION OF orders_partition_test
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

INSERT INTO orders_partition_test (customer_id, status, ordered_at)
SELECT customer_id, status, ordered_at FROM orders;

EXPLAIN ANALYZE
SELECT * FROM orders_partition_test WHERE ordered_at > '2025-12-01';

DROP TABLE orders_partition_test_2024;  -- 파티션 즉시 삭제 데모

DROP TABLE orders_partition_test;  -- 전체 정리
