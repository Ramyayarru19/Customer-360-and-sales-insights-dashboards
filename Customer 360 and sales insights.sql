
-- Customer 360 & Sales Insights Dashboard — Snowflake SQL


-- 01. DATABASE & WAREHOUSE SETUP


CREATE DATABASE IF NOT EXISTS CUSTOMER360_DB;
CREATE SCHEMA  IF NOT EXISTS CUSTOMER360_DB.ANALYTICS;
USE SCHEMA CUSTOMER360_DB.ANALYTICS;

CREATE WAREHOUSE IF NOT EXISTS BI_WAREHOUSE
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND   = 300
  AUTO_RESUME    = TRUE
  COMMENT        = 'Dedicated warehouse for Power BI DirectQuery';



-- 02. DIMENSION TABLES

-- DIM_DATE: Generated date spine (run once)
CREATE OR REPLACE TABLE DIM_DATE (
  date_key      NUMBER       PRIMARY KEY,          -- YYYYMMDD integer
  date_full     DATE         NOT NULL,
  day_of_week   NUMBER(1),                         -- 0=Sunday
  day_name      VARCHAR(10),
  week_of_year  NUMBER(2),
  month_num     NUMBER(2),
  month_name    VARCHAR(10),
  quarter       NUMBER(1),
  year          NUMBER(4),
  is_weekend    BOOLEAN,
  is_holiday    BOOLEAN DEFAULT FALSE
);

-- Populate DIM_DATE for 5 years
INSERT INTO DIM_DATE
SELECT
  TO_NUMBER(TO_CHAR(d.d, 'YYYYMMDD'))          AS date_key,
  d.d                                           AS date_full,
  DAYOFWEEK(d.d)                                AS day_of_week,
  DAYNAME(d.d)                                  AS day_name,
  WEEKOFYEAR(d.d)                               AS week_of_year,
  MONTH(d.d)                                    AS month_num,
  MONTHNAME(d.d)                                AS month_name,
  QUARTER(d.d)                                  AS quarter,
  YEAR(d.d)                                     AS year,
  DAYOFWEEK(d.d) IN (0, 6)                      AS is_weekend,
  FALSE                                         AS is_holiday
FROM (
  SELECT DATEADD('day', SEQ4(), '2020-01-01')::DATE AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 1826))  -- 5 years
) d;


-- DIM_CUSTOMER
CREATE OR REPLACE TABLE DIM_CUSTOMER (
  customer_key        NUMBER        AUTOINCREMENT PRIMARY KEY,
  customer_id         VARCHAR(50)   NOT NULL UNIQUE,
  full_name           VARCHAR(150),
  email               VARCHAR(200),
  phone               VARCHAR(30),
  segment             VARCHAR(50),  -- Enterprise / SMB / Consumer
  tier                VARCHAR(20),  -- Gold / Silver / Bronze
  acquisition_channel VARCHAR(80),  -- Organic / Paid / Referral / Direct
  first_purchase_date DATE,
  last_purchase_date  DATE,
  city                VARCHAR(100),
  country             VARCHAR(80),
  is_active           BOOLEAN DEFAULT TRUE,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


-- DIM_PRODUCT
CREATE OR REPLACE TABLE DIM_PRODUCT (
  product_key   NUMBER        AUTOINCREMENT PRIMARY KEY,
  product_id    VARCHAR(50)   NOT NULL UNIQUE,
  sku           VARCHAR(60),
  product_name  VARCHAR(200),
  category      VARCHAR(80),
  subcategory   VARCHAR(80),
  brand         VARCHAR(80),
  unit_price    NUMBER(12, 2),
  unit_cost     NUMBER(12, 2),
  is_active     BOOLEAN DEFAULT TRUE
);


-- DIM_GEOGRAPHY
CREATE OR REPLACE TABLE DIM_GEOGRAPHY (
  geo_key     NUMBER       AUTOINCREMENT PRIMARY KEY,
  city        VARCHAR(100),
  state       VARCHAR(100),
  country     VARCHAR(80),
  region      VARCHAR(80),  -- North / South / East / West / International
  postal_code VARCHAR(20)
);



-- 03. FACT TABLE

CREATE OR REPLACE TABLE FACT_SALES (
  sale_id       VARCHAR(60)    PRIMARY KEY,
  customer_key  NUMBER         REFERENCES DIM_CUSTOMER(customer_key),
  product_key   NUMBER         REFERENCES DIM_PRODUCT(product_key),
  date_key      NUMBER         REFERENCES DIM_DATE(date_key),
  geo_key       NUMBER         REFERENCES DIM_GEOGRAPHY(geo_key),
  sale_date     DATE           NOT NULL,
  quantity      NUMBER(8),
  unit_price    NUMBER(12, 2),
  discount_pct  NUMBER(5, 4)   DEFAULT 0,
  revenue       NUMBER(14, 2)  GENERATED ALWAYS AS
                  (quantity * unit_price * (1 - discount_pct)) VIRTUAL,
  cost          NUMBER(14, 2),
  gross_margin  NUMBER(14, 2)  GENERATED ALWAYS AS
                  (revenue - cost) VIRTUAL,
  is_returned   BOOLEAN        DEFAULT FALSE,
  is_churned    BOOLEAN        DEFAULT FALSE,
  loaded_at     TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (date_key, customer_key);  -- Optimise for BI queries on date + customer



-- 04. ANALYTICS VIEWS — Customer Behaviour

-- V_CUSTOMER_CLV: Customer Lifetime Value calculation
CREATE OR REPLACE VIEW V_CUSTOMER_CLV AS
WITH customer_stats AS (
  SELECT
    c.customer_key,
    c.customer_id,
    c.full_name,
    c.segment,
    c.tier,
    c.acquisition_channel,
    COUNT(DISTINCT s.sale_id)                         AS total_orders,
    SUM(s.revenue)                                    AS total_revenue,
    AVG(s.revenue)                                    AS avg_order_value,
    DATEDIFF('month', MIN(s.sale_date), MAX(s.sale_date)) + 1
                                                      AS lifespan_months,
    MIN(s.sale_date)                                  AS first_purchase,
    MAX(s.sale_date)                                  AS last_purchase
  FROM DIM_CUSTOMER c
  JOIN FACT_SALES s ON c.customer_key = s.customer_key
  WHERE s.is_returned = FALSE
  GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT
  *,
  -- Purchase frequency (orders per month)
  ROUND(total_orders / NULLIF(lifespan_months, 0), 4)     AS purchase_freq_monthly,
  -- Projected CLV over 12-month horizon
  ROUND(avg_order_value
        * (total_orders / NULLIF(lifespan_months, 0))
        * 12, 2)                                          AS projected_clv_12m,
  -- Recency: days since last purchase
  DATEDIFF('day', last_purchase, CURRENT_DATE())          AS recency_days
FROM customer_stats;


-- V_CHURN_RISK: Segment customers by churn risk band
CREATE OR REPLACE VIEW V_CHURN_RISK AS
WITH recency AS (
  SELECT
    c.customer_id,
    c.full_name,
    c.segment,
    c.tier,
    c.acquisition_channel,
    MAX(s.sale_date)                               AS last_purchase_date,
    DATEDIFF('day', MAX(s.sale_date), CURRENT_DATE())
                                                   AS days_since_purchase,
    COUNT(DISTINCT s.sale_id)                      AS total_orders,
    SUM(s.revenue)                                 AS total_revenue
  FROM DIM_CUSTOMER c
  LEFT JOIN FACT_SALES s ON c.customer_key = s.customer_key
  WHERE c.is_active = TRUE
  GROUP BY 1, 2, 3, 4, 5
)
SELECT
  *,
  CASE
    WHEN days_since_purchase > 180 THEN 'High Risk'
    WHEN days_since_purchase > 90  THEN 'Medium Risk'
    WHEN days_since_purchase > 30  THEN 'Low Risk'
    ELSE                                'Active'
  END                                              AS churn_risk_band,
  ROUND(total_revenue / NULLIF(total_orders, 0), 2) AS avg_order_value
FROM recency
ORDER BY days_since_purchase DESC;


-- V_COHORT_RETENTION: Monthly cohort retention matrix
CREATE OR REPLACE VIEW V_COHORT_RETENTION AS
WITH cohorts AS (
  SELECT
    c.customer_id,
    DATE_TRUNC('month', c.first_purchase_date)  AS cohort_month,
    DATE_TRUNC('month', s.sale_date)            AS activity_month
  FROM DIM_CUSTOMER c
  JOIN FACT_SALES s ON c.customer_key = s.customer_key
),
cohort_size AS (
  SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_customers
  FROM cohorts
  GROUP BY 1
)
SELECT
  c.cohort_month,
  c.activity_month,
  DATEDIFF('month', c.cohort_month, c.activity_month) AS period_number,
  COUNT(DISTINCT c.customer_id)                        AS retained_customers,
  cs.cohort_customers,
  ROUND(100.0 * COUNT(DISTINCT c.customer_id) / cs.cohort_customers, 2)
                                                       AS retention_rate_pct
FROM cohorts c
JOIN cohort_size cs ON c.cohort_month = cs.cohort_month
GROUP BY 1, 2, 3, 5
ORDER BY 1, 3;


-- V_RFM_SCORES: RFM segmentation (Recency, Frequency, Monetary)
CREATE OR REPLACE VIEW V_RFM_SCORES AS
WITH rfm_raw AS (
  SELECT
    c.customer_id,
    c.full_name,
    c.segment,
    DATEDIFF('day', MAX(s.sale_date), CURRENT_DATE())  AS recency_days,
    COUNT(DISTINCT s.sale_id)                           AS frequency,
    SUM(s.revenue)                                      AS monetary
  FROM DIM_CUSTOMER c
  JOIN FACT_SALES s ON c.customer_key = s.customer_key
  WHERE s.is_returned = FALSE
  GROUP BY 1, 2, 3
),
rfm_scored AS (
  SELECT *,
    NTILE(5) OVER (ORDER BY recency_days ASC)  AS r_score,  -- lower days = better
    NTILE(5) OVER (ORDER BY frequency DESC)    AS f_score,
    NTILE(5) OVER (ORDER BY monetary DESC)     AS m_score
  FROM rfm_raw
)
SELECT
  *,
  CONCAT(r_score, f_score, m_score) AS rfm_cell,
  CASE
    WHEN r_score >= 4 AND f_score >= 4              THEN 'Champions'
    WHEN r_score >= 3 AND f_score >= 3              THEN 'Loyal Customers'
    WHEN r_score >= 4 AND f_score <= 2              THEN 'Recent Customers'
    WHEN r_score <= 2 AND f_score >= 3              THEN 'At Risk'
    WHEN r_score <= 1 AND f_score <= 2              THEN 'Lost'
    ELSE                                                 'Potential Loyalists'
  END AS rfm_segment
FROM rfm_scored;


-- V_BEHAVIOUR_CORRELATION: Segment-level behaviour patterns
CREATE OR REPLACE VIEW V_BEHAVIOUR_CORRELATION AS
SELECT
  c.segment,
  c.tier,
  c.acquisition_channel,
  COUNT(DISTINCT c.customer_id)         AS customer_count,
  ROUND(AVG(clv.projected_clv_12m), 2) AS avg_clv,
  ROUND(AVG(clv.purchase_freq_monthly), 4) AS avg_purchase_freq,
  ROUND(AVG(clv.avg_order_value), 2)    AS avg_order_value,
  ROUND(AVG(clv.recency_days), 1)       AS avg_recency_days,
  ROUND(SUM(clv.total_revenue), 2)      AS segment_total_revenue,
  RANK() OVER (ORDER BY AVG(clv.projected_clv_12m) DESC) AS segment_clv_rank
FROM DIM_CUSTOMER c
JOIN V_CUSTOMER_CLV clv ON c.customer_id = clv.customer_id
GROUP BY 1, 2, 3
ORDER BY avg_clv DESC;



-- 05. POWER BI OPTIMISATION LAYER


-- Pre-aggregated monthly table to reduce DirectQuery fan-out
CREATE OR REPLACE TABLE AGG_SALES_MONTHLY AS
SELECT
  d.year,
  d.month_num,
  d.month_name,
  d.quarter,
  c.segment,
  c.tier,
  c.acquisition_channel,
  p.category,
  p.subcategory,
  g.region,
  COUNT(DISTINCT s.customer_key)                        AS unique_customers,
  COUNT(s.sale_id)                                      AS total_orders,
  ROUND(SUM(s.revenue), 2)                              AS total_revenue,
  ROUND(SUM(s.gross_margin), 2)                         AS total_margin,
  ROUND(AVG(s.revenue), 2)                              AS avg_order_value,
  SUM(CASE WHEN s.is_returned THEN 1 ELSE 0 END)        AS returns_count,
  SUM(CASE WHEN s.is_churned  THEN 1 ELSE 0 END)        AS churned_count,
  ROUND(
    100.0 * SUM(CASE WHEN s.is_churned THEN 1 ELSE 0 END)
    / NULLIF(COUNT(DISTINCT s.customer_key), 0), 2)     AS churn_rate_pct
FROM FACT_SALES s
JOIN DIM_DATE       d ON s.date_key     = d.date_key
JOIN DIM_CUSTOMER   c ON s.customer_key = c.customer_key
JOIN DIM_PRODUCT    p ON s.product_key  = p.product_key
JOIN DIM_GEOGRAPHY  g ON s.geo_key      = g.geo_key
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;

─