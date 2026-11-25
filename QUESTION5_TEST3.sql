--(a) Database and Seed Data [6 marks]
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    tier        VARCHAR(20) NOT NULL DEFAULT 'STANDARD'
                CHECK (tier IN ('STANDARD', 'PREMIUM'))
);

CREATE TABLE product (
    product_id   SERIAL PRIMARY KEY,
    sku          VARCHAR(40) NOT NULL UNIQUE,
    product_name VARCHAR(150) NOT NULL,
    unit_price   NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty    INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE orderS (
    order_id     SERIAL PRIMARY KEY,
    customer_id  INTEGER NOT NULL REFERENCES customers(customer_id),
    ordered_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING', 'CONFIRMED', 'SHIPPED', 'CANCELLED'))
);

CREATE TABLE order_items (
    item_id     SERIAL PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id  INTEGER NOT NULL REFERENCES products(product_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    CONSTRAINT uq_order_product UNIQUE (order_id, product_id)
);

CREATE TABLE order_status_audit (
    audit_id   SERIAL PRIMARY KEY,
    order_id   INTEGER NOT NULL REFERENCES orders(order_id),
    old_status VARCHAR(20) NOT NULL,
    new_status VARCHAR(20) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed at least three customers
INSERT INTO customers (full_name, email, tier) VALUES
    ('Lubuto Mwanza',   'lubuto.mwanza@shop.zm',   'PREMIUM'),
    ('Chipo Kalumba',   'chipo.kalumba@shop.zm',   'STANDARD'),
    ('Dalitso Gondwe',  'dalitso.gondwe@shop.zm',  'PREMIUM');

-- Seed at least four products
INSERT INTO products (sku, product_name, unit_price, stock_qty) VALUES
    ('SKU-1001', 'Wireless Mechanical Keyboard', 1250.00, 15),
    ('SKU-1002', 'USB-C Docking Station',        1850.00, 8),
    ('SKU-1003', '27-Inch IPS Monitor',          4200.00, 5),
    ('SKU-1004', 'Noise-Cancelling Headset',     1600.00, 12);
--(b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_order_net_total(
    p_order_id INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_subtotal NUMERIC(12, 2);
    v_tier     VARCHAR(20);
    v_discount NUMERIC(5, 2);
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'p_order_id cannot be NULL.';
    END IF;

    SELECT c.tier
      INTO v_tier
      FROM orders o
      JOIN customers c ON c.customer_id = o.customer_id
     WHERE o.order_id = p_order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown order_id: %', p_order_id;
    END IF;

    SELECT COALESCE(SUM(quantity * unit_price), 0.00)
      INTO v_subtotal
      FROM order_items
     WHERE order_id = p_order_id;

    v_discount := CASE WHEN v_tier = 'PREMIUM' THEN 0.10 ELSE 0.00 END;

    RETURN ROUND(v_subtotal * (1 - v_discount), 2);
END;
$$;

--(c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_place_order(
    p_customer_id INTEGER,
    p_product_id  INTEGER,
    p_quantity    INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price    NUMERIC(10, 2);
    v_stock    INTEGER;
    v_order_id INTEGER;
BEGIN
    IF p_customer_id IS NULL OR p_product_id IS NULL
       OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid order input: customer_id=%, product_id=%, quantity=%',
            p_customer_id, p_product_id, p_quantity;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Customer % does not exist.', p_customer_id;
    END IF;

    -- Lock product row to serialize concurrent stock deductions
    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM products
     WHERE product_id = p_product_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product % does not exist.', p_product_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %: available %, requested %.',
            p_product_id, v_stock, p_quantity;
    END IF;

    -- Create order in PENDING state
    INSERT INTO orders (customer_id, ordered_at, total_amount, status)
    VALUES (p_customer_id, CURRENT_TIMESTAMP, 0.00, 'PENDING')
    RETURNING order_id INTO v_order_id;

    -- Insert line item locking in unit price
    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    -- Deduct inventory
    UPDATE products
       SET stock_qty = stock_qty - p_quantity
     WHERE product_id = p_product_id;

    -- Finalize total and confirm order (fires status audit trigger)
    UPDATE orders
       SET total_amount = fn_order_net_total(v_order_id),
           status       = 'CONFIRMED'
     WHERE order_id = v_order_id;
END;
$$;
--(d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_fn_orders_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO order_status_audit (order_id, old_status, new_status, changed_at)
        VALUES (NEW.order_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);

        -- Restock items if a confirmed order is cancelled
        IF OLD.status = 'CONFIRMED' AND NEW.status = 'CANCELLED' THEN
            UPDATE products p
               SET stock_qty = p.stock_qty + oi.quantity
              FROM order_items oi
             WHERE oi.order_id   = NEW.order_id
               AND oi.product_id = p.product_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_orders_after_update_status
AFTER UPDATE OF status ON orders
FOR EACH ROW
EXECUTE FUNCTION trg_fn_orders_status_change();

CALL pr_place_order(1, 1, 2); -- Premium customer: 2 keyboards
CALL pr_place_order(2, 2, 1); -- Standard customer: 1 docking station
CALL pr_place_order(3, 3, 1); -- Premium customer: 1 monitor
CALL pr_place_order(1, 4, 3); -- Premium customer: 3 headsets
CALL pr_place_order(2, 1, 1); -- Standard customer: 1 keyboard

-- Ship order 1 and cancel order 5 (triggers audit + stock restoration)
UPDATE orders SET status = 'SHIPPED'   WHERE order_id = 1;
UPDATE orders SET status = 'CANCELLED' WHERE order_id = 5;

--(e) View [5 marks]
CREATE OR REPLACE VIEW v_fulfillment_queue AS
SELECT
    o.order_id,
    o.ordered_at,
    o.status,
    c.customer_id,
    c.full_name AS customer_name,
    c.tier      AS customer_tier,
    COUNT(oi.item_id)    AS line_count,
    SUM(oi.quantity)     AS total_units,
    o.total_amount
FROM orders o
JOIN customers   c  ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
WHERE o.status IN ('PENDING', 'CONFIRMED')
GROUP BY
    o.order_id, o.ordered_at, o.status,
    c.customer_id, c.full_name, c.tier, o.total_amount;

-- Query open warehouse dispatch queue
SELECT *
  FROM v_fulfillment_queue
 ORDER BY ordered_at ASC;

--(f) index[5 marks]
CREATE INDEX idx_orders_status_ordered_at
    ON orders (status, ordered_at);

EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, ordered_at, total_amount
  FROM orders
 WHERE status = 'CONFIRMED'
   AND ordered_at >= CURRENT_TIMESTAMP - INTERVAL '7 days'
 ORDER BY ordered_at ASC;

 --(g) Scheduled Job [6 marks]
 CREATE OR REPLACE PROCEDURE pr_expire_stale_pending_orders(
    p_cutoff TIMESTAMP DEFAULT CURRENT_TIMESTAMP - INTERVAL '24 hours'
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_cutoff IS NULL THEN
        RAISE EXCEPTION 'p_cutoff cannot be NULL.';
    END IF;

    UPDATE orders
       SET status = 'CANCELLED'
     WHERE status = 'PENDING'
       AND ordered_at < p_cutoff;
END;
$$;

-- Schedule hourly at minute 0 using pg_cron
SELECT cron.schedule(
    'hourly_expire_pending_orders',
    '0 * * * *',
    $$CALL pr_expire_stale_pending_orders(CURRENT_TIMESTAMP - INTERVAL '24 hours');$$
);