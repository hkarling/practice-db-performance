-- ========== master / reference tables ==========
CREATE TABLE customers
(
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(150) NOT NULL,
    city       VARCHAR(100) NOT NULL,
    state      VARCHAR(2)   NOT NULL,
    zip_code   VARCHAR(10)  NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE sellers
(
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    city       VARCHAR(100) NOT NULL,
    state      VARCHAR(2)   NOT NULL,
    zip_code   VARCHAR(10)  NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE categories
(
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE products
(
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id BIGINT       NOT NULL REFERENCES categories (id),
    name        VARCHAR(200) NOT NULL,
    weight_g    INTEGER,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ========== transactional tables ==========
CREATE TABLE orders
(
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT      NOT NULL REFERENCES customers (id),
    status      VARCHAR(20) NOT NULL
        CHECK (status IN ('PROCESSING', 'SHIPPED', 'DELIVERED', 'CANCELLED', 'REFUNDED')),
    ordered_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE order_items
(
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      BIGINT         NOT NULL REFERENCES orders (id),
    product_id    BIGINT         NOT NULL REFERENCES products (id),
    seller_id     BIGINT         NOT NULL REFERENCES sellers (id),
    price         NUMERIC(10, 2) NOT NULL,
    freight_value NUMERIC(10, 2) NOT NULL,
    created_at    TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE TABLE order_payments
(
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      BIGINT         NOT NULL REFERENCES orders (id),
    payment_type  VARCHAR(20)    NOT NULL
        CHECK (payment_type IN ('CREDIT_CARD', 'BOLETO', 'VOUCHER', 'DEBIT_CARD')),
    installments  SMALLINT       NOT NULL DEFAULT 1,
    payment_value NUMERIC(10, 2) NOT NULL,
    status        VARCHAR(20)    NOT NULL
        CHECK (status IN ('PAID', 'REFUNDED')),
    created_at    TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE TABLE order_reviews
(
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   BIGINT      NOT NULL REFERENCES orders (id),
    rating     SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment    TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE delivery
(
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id              BIGINT      NOT NULL UNIQUE REFERENCES orders (id),
    shipped_at            TIMESTAMPTZ,
    delivered_at          TIMESTAMPTZ,
    estimated_delivery_at TIMESTAMPTZ NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ========== indexes ==========
CREATE INDEX idx_orders_customer_id ON orders (customer_id);
CREATE INDEX idx_orders_status_ordered_at ON orders (status, ordered_at DESC);
CREATE INDEX idx_order_items_product_id ON order_items (product_id);

-- ========== updated_at 자동 갱신 트리거 ==========
CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE
    ON customers
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sellers_updated_at
    BEFORE UPDATE
    ON sellers
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_categories_updated_at
    BEFORE UPDATE
    ON categories
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE
    ON products
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE
    ON orders
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_order_items_updated_at
    BEFORE UPDATE
    ON order_items
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_order_payments_updated_at
    BEFORE UPDATE
    ON order_payments
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_order_reviews_updated_at
    BEFORE UPDATE
    ON order_reviews
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_delivery_updated_at
    BEFORE UPDATE
    ON delivery
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();