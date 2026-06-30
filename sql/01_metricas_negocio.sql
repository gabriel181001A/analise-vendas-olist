-- ============================================================
-- Olist E-commerce — Queries de métricas de negócio
-- Dialeto: SQLite/PostgreSQL (ajuste nomes de tabela conforme seu import)
-- Tabelas esperadas (CSVs do Kaggle):
--   olist_orders_dataset            -> orders
--   olist_order_items_dataset       -> order_items
--   olist_order_payments_dataset    -> payments
--   olist_order_reviews_dataset     -> reviews
--   olist_customers_dataset         -> customers
--   olist_products_dataset          -> products
--   product_category_name_translation -> category_translation
-- ============================================================


-- ------------------------------------------------------------
-- 1) Receita total e nº de pedidos por mês
-- ------------------------------------------------------------
SELECT
    STRFTIME('%Y-%m', o.order_purchase_timestamp) AS mes,
    COUNT(DISTINCT o.order_id)                     AS qtd_pedidos,
    ROUND(SUM(p.payment_value), 2)                 AS receita_total
FROM orders o
JOIN payments p ON p.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- 2) Receita e ticket médio por estado do cliente (UF)
-- ------------------------------------------------------------
SELECT
    c.customer_state                               AS uf,
    COUNT(DISTINCT o.order_id)                     AS qtd_pedidos,
    ROUND(SUM(p.payment_value), 2)                 AS receita_total,
    ROUND(SUM(p.payment_value) / COUNT(DISTINCT o.order_id), 2) AS ticket_medio
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN payments  p ON p.order_id    = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY receita_total DESC;


-- ------------------------------------------------------------
-- 3) Top 10 categorias por receita (com tradução p/ inglês)
-- ------------------------------------------------------------
SELECT
    COALESCE(t.product_category_name_english, pr.product_category_name) AS categoria,
    COUNT(oi.order_id)                              AS qtd_itens,
    ROUND(SUM(oi.price), 2)                         AS receita_itens
FROM order_items oi
JOIN products pr ON pr.product_id = oi.product_id
LEFT JOIN category_translation t ON t.product_category_name = pr.product_category_name
GROUP BY categoria
ORDER BY receita_itens DESC
LIMIT 10;


-- ------------------------------------------------------------
-- 4) Logística x satisfação:
--    nota média de avaliação por faixa de atraso na entrega
--    (entrega real - entrega estimada, em dias)
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN JULIANDAY(o.order_delivered_customer_date) - JULIANDAY(o.order_estimated_delivery_date) <= 0
            THEN 'No prazo ou adiantado'
        WHEN JULIANDAY(o.order_delivered_customer_date) - JULIANDAY(o.order_estimated_delivery_date) <= 5
            THEN 'Atraso 1-5 dias'
        ELSE 'Atraso > 5 dias'
    END                                            AS faixa_atraso,
    COUNT(*)                                        AS qtd_pedidos,
    ROUND(AVG(r.review_score), 2)                   AS nota_media
FROM orders o
JOIN reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_estimated_delivery_date IS NOT NULL
GROUP BY faixa_atraso
ORDER BY nota_media DESC;


-- ------------------------------------------------------------
-- 5) Taxa de recompra: % de clientes com mais de 1 pedido
--    (usa customer_unique_id = pessoa real, não o id por pedido)
-- ------------------------------------------------------------
WITH pedidos_por_cliente AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS qtd_pedidos
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    GROUP BY c.customer_unique_id
)
SELECT
    COUNT(*)                                                       AS total_clientes,
    SUM(CASE WHEN qtd_pedidos > 1 THEN 1 ELSE 0 END)              AS clientes_recorrentes,
    ROUND(100.0 * SUM(CASE WHEN qtd_pedidos > 1 THEN 1 ELSE 0 END) / COUNT(*), 2) AS taxa_recompra_pct
FROM pedidos_por_cliente;
