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


-- ------------------------------------------------------------
-- 6) Segmentação RFM de clientes
--    Recência (dias desde a última compra), Frequência (nº de pedidos)
--    e Monetário (total gasto), com nota 1-5 por quintil (NTILE).
--    Segmento definido por R e M (a Frequência quase não varia: recompra ~3%).
-- ------------------------------------------------------------
WITH base AS (
    SELECT
        c.customer_unique_id,
        MAX(o.order_purchase_timestamp)     AS ultima_compra,
        COUNT(DISTINCT o.order_id)          AS frequencia,
        SUM(p.payment_value)                AS monetario
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN payments  p ON p.order_id    = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
rfm AS (
    SELECT
        customer_unique_id,
        frequencia,
        monetario,
        -- recência em dias em relação à data de referência (máxima da base)
        JULIANDAY((SELECT MAX(ultima_compra) FROM base)) - JULIANDAY(ultima_compra) AS recencia,
        6 - NTILE(5) OVER (ORDER BY ultima_compra DESC) AS r_score,   -- mais recente = nota maior
        NTILE(5) OVER (ORDER BY monetario ASC)          AS m_score     -- gasta mais = nota maior
    FROM base
),
segmentado AS (
    SELECT
        customer_unique_id, recencia, frequencia, monetario, r_score, m_score,
        CASE
            WHEN r_score >= 4 AND m_score >= 4 THEN 'Campeões'
            WHEN m_score >= 4                  THEN 'Alto valor'
            WHEN r_score >= 4                  THEN 'Clientes recentes'
            WHEN r_score <= 2 AND m_score >= 3 THEN 'Em risco'
            WHEN r_score <= 2                  THEN 'Hibernando'
            ELSE 'Intermediários'
        END AS segmento
    FROM rfm
)
SELECT
    segmento,
    COUNT(*)                          AS clientes,
    ROUND(SUM(monetario), 2)          AS receita_total,
    ROUND(AVG(monetario), 2)          AS ticket_medio,
    ROUND(AVG(recencia), 0)           AS recencia_media_dias
FROM segmentado
GROUP BY segmento
ORDER BY receita_total DESC;
