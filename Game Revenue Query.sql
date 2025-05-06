-- Calculate Monthly Revenue per User
WITH monthly_revenue AS (
    SELECT 
        DATE_TRUNC('month', payment_date) AS month,
        user_id,
        SUM(revenue_amount_usd) AS revenue
    FROM project.games_payments
    GROUP BY month, user_id
),
-- Calculate Total Paid Users and MRR
paid_users AS (
    SELECT 
        month,
        COUNT(DISTINCT user_id) AS total_paid_users,
        SUM(revenue) AS MRR
    FROM monthly_revenue
    GROUP BY month
),
-- Calculate ARPPU
arppu AS (
    SELECT 
        month,
        ROUND(CASE 
            WHEN total_paid_users > 0 THEN MRR / total_paid_users 
            ELSE 0 
        END, 2) AS ARPPU
    FROM paid_users
),
--  Identify the First Payment Date for Each User
first_payment AS (
    SELECT 
        user_id, 
        MIN(payment_date) AS first_payment_date
    FROM project.games_payments
    GROUP BY user_id
),
--  Count New Paid Users per Month
new_paid_users AS (
    SELECT 
        DATE_TRUNC('month', first_payment_date) AS month,
        COUNT(user_id) AS new_paid_users
    FROM first_payment
    GROUP BY month
),
--  Calculate New MRR 
new_mrr AS (
    SELECT 
        DATE_TRUNC('month', gp.payment_date) AS month,
        SUM(gp.revenue_amount_usd) AS new_MRR
    FROM project.games_payments gp
    JOIN first_payment fp ON gp.user_id = fp.user_id
    WHERE DATE_TRUNC('month', gp.payment_date) = DATE_TRUNC('month', fp.first_payment_date)
    GROUP BY month
),
-- Determine the Last Payment Date for Each User Per Month
last_payment_per_month AS (
    SELECT 
        user_id,
        DATE_TRUNC('month', payment_date) AS month,
        MAX(payment_date) AS last_payment_date
    FROM project.games_payments
    GROUP BY user_id, month
),
--  Determine the First Payment Date for Each User Per Month
first_payment_per_month AS (
    SELECT 
        user_id, 
        DATE_TRUNC('month', payment_date) AS month, 
        MIN(payment_date) AS first_payment_date   
    FROM project.games_payments
    GROUP BY user_id, month
),
-- Identify Churned Users 
churned_users_monthly AS (
    SELECT 
        lp.month + INTERVAL '1 month' AS churn_month,
        COUNT(DISTINCT lp.user_id) AS churned_users
    FROM last_payment_per_month lp
    LEFT JOIN first_payment_per_month fp 
        ON lp.user_id = fp.user_id 
        AND fp.month = lp.month + INTERVAL '1 month' 
    WHERE fp.user_id IS NULL
    GROUP BY 1
),
-- Calculate Churned Revenue 
churned_revenue AS (
    SELECT 
        lp.month + INTERVAL '1 month' AS churn_month,
        -SUM(mr.revenue) AS churned_revenue  -- Negatif değer almak için
    FROM last_payment_per_month lp
    JOIN monthly_revenue mr ON lp.user_id = mr.user_id 
        AND lp.month = mr.month
    LEFT JOIN first_payment_per_month fp 
        ON lp.user_id = fp.user_id 
        AND fp.month = lp.month + INTERVAL '1 month' 
    WHERE fp.user_id IS NULL
    GROUP BY 1
),
--  Calculate Churn Rate (Churned Users / Previous Month Paid Users)
churn_rate_calc AS (
    SELECT 
        c.churn_month,
        c.churned_users,
        p.total_paid_users AS previous_month_paid_users,
        ROUND(CASE 
            WHEN p.total_paid_users > 0 THEN c.churned_users::decimal / p.total_paid_users 
            ELSE 0 
        END, 2) AS churn_rate
    FROM churned_users_monthly c
    LEFT JOIN paid_users p ON c.churn_month = p.month + INTERVAL '1 month'
),
--  Calculate Previous Month's MRR for Revenue Churn Rate Calculation
previous_mrr_calc AS (
    SELECT 
        month, 
        MRR, 
        LAG(MRR) OVER (ORDER BY month) AS previous_month_MRR
    FROM paid_users
),
--  Calculate Revenue Churn Rate (Lost Revenue / Previous Month MRR)
revenue_churn AS (
    SELECT 
        cr.churn_month,
        cr.churned_revenue,
        pm.previous_month_MRR,
        ROUND(CASE 
            WHEN pm.previous_month_MRR > 0 THEN ABS(cr.churned_revenue) / pm.previous_month_MRR
            ELSE 0 
        END, 2) AS revenue_churn_rate
    FROM churned_revenue cr
    LEFT JOIN previous_mrr_calc pm ON cr.churn_month = pm.month
 ),
--  Calculate Expansion and Contraction MRR 
expansion_contraction_mrr AS (
    SELECT 
        prev.month + INTERVAL '1 month' AS month,
        SUM(
            CASE 
                WHEN curr.revenue > prev.revenue THEN curr.revenue - prev.revenue 
                ELSE 0 
            END
        ) AS expansion_MRR,
        SUM(
            CASE 
                WHEN curr.revenue < prev.revenue THEN -(prev.revenue - curr.revenue) 
                ELSE 0 
            END
        ) AS contraction_MRR
    FROM monthly_revenue prev
    JOIN monthly_revenue curr 
        ON prev.user_id = curr.user_id 
        AND curr.month = prev.month + INTERVAL '1 month'
    GROUP BY 1
)
--  Final Data Selection 
SELECT 
    TO_CHAR(p.month, 'YYYY-MM-DD') AS month,
    p.MRR,
    p.total_paid_users,
    a.ARPPU,
    np.new_paid_users,
    nm.new_MRR,
    COALESCE(e.expansion_MRR, 0) AS expansion_MRR,
    COALESCE(s.contraction_MRR, 0) AS contraction_MRR,
    COALESCE(cr.churned_users, 0) AS churned_users,
    COALESCE(churn_rate_calc.churn_rate, 0) AS churn_rate,
    COALESCE(churned_rev.churned_revenue, 0) AS churned_revenue,
    COALESCE(rc.revenue_churn_rate, 0) AS revenue_churn_rate
FROM paid_users p
LEFT JOIN arppu a ON p.month = a.month
LEFT JOIN new_paid_users np ON p.month = np.month
LEFT JOIN new_mrr nm ON p.month = nm.month
LEFT JOIN expansion_contraction_mrr e ON p.month = e.month
LEFT JOIN expansion_contraction_mrr s ON p.month = s.month
LEFT JOIN churned_users_monthly cr ON p.month = cr.churn_month
LEFT JOIN churned_revenue churned_rev ON p.month = churned_rev.churn_month  
LEFT JOIN churn_rate_calc ON p.month = churn_rate_calc.churn_month  
LEFT JOIN revenue_churn rc ON p.month = rc.churn_month
ORDER BY p.month;
