USE [stock_medcine db];
GO

-- Har table ka count dekho
SELECT 'medicines_master' as Table_Name, COUNT(*) as Total_Rows FROM medicines_master
UNION ALL
SELECT 'suppliers_master', COUNT(*) FROM suppliers_master
UNION ALL
SELECT 'purchases_transactions', COUNT(*) FROM purchases_transactions
UNION ALL
SELECT 'sales_transactions', COUNT(*) FROM sales_transactions
UNION ALL
SELECT 'reorder_levels', COUNT(*) FROM reorder_levels;
GO

-- =============================================
-- QUERY 1: Current Stock Status (Modified)
-- Database: stock_medcine_db
-- Tables: medicines_master, purchases_transactions
-- =============================================

USE [stock_medcine db];
GO

-- Pehle check karo agar table exist karta hai toh drop karo
IF OBJECT_ID('tempdb..#current_stock_summary') IS NOT NULL
    DROP TABLE #current_stock_summary;
GO

-- Ab naya table banao
SELECT 
    -- Medicines table se columns
    m.medicine_id,
    m.medicine_name,
    m.category,
    m.therapeutic_class,
    m.manufacturer,
    m.is_emergency,
    m.is_refrigerated,
    
    -- Purchases table se calculated columns
    ISNULL(SUM(p.quantity_remaining), 0) as current_stock,
    COUNT(DISTINCT p.batch_no) as total_batches,
    MIN(p.expiry_date) as earliest_expiry,
    MAX(p.expiry_date) as latest_expiry,
    
    -- Stock status
    CASE 
        WHEN ISNULL(SUM(p.quantity_remaining), 0) = 0 THEN 'OUT OF STOCK'
        WHEN ISNULL(SUM(p.quantity_remaining), 0) < 30 THEN 'LOW STOCK'
        WHEN ISNULL(SUM(p.quantity_remaining), 0) < 100 THEN 'ADEQUATE'
        ELSE 'HIGH STOCK'
    END as stock_status
    
INTO #current_stock_summary

FROM medicines_master m
LEFT JOIN purchases_transactions p 
    ON m.medicine_id = p.medicine_id 
    AND p.expiry_date > GETDATE()
    AND p.quantity_remaining > 0

GROUP BY 
    m.medicine_id, 
    m.medicine_name, 
    m.category,
    m.therapeutic_class,
    m.manufacturer,
    m.is_emergency,
    m.is_refrigerated;

-- Result dekho
SELECT * FROM #current_stock_summary 
ORDER BY current_stock DESC;
GO

-- =============================================
-- QUERY 2: Low Stock Alert
-- Database: stock_medcine_db
-- Tables: #current_stock_summary, reorder_levels
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 2: Low Stock Alert...';
GO

-- Check if temporary table exists
IF OBJECT_ID('tempdb..#current_stock_summary') IS NULL
BEGIN
    PRINT '❌ ERROR: #current_stock_summary table not found!';
    PRINT 'Please run Query 1 first.';
    RETURN;
END
GO

-- Check if reorder_levels table exists
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'reorder_levels')
BEGIN
    PRINT '❌ ERROR: reorder_levels table not found!';
    RETURN;
END
GO

-- Low Stock Alert
SELECT 
    -- Medicine details
    cs.medicine_name,
    cs.category,
    cs.manufacturer,
    cs.is_emergency,
    
    -- Stock details
    cs.current_stock,
    ISNULL(rl.min_stock_level, 0) as min_stock_level,
    ISNULL(rl.reorder_quantity, 0) as reorder_quantity,
    
    -- Calculations (handle NULL values)
    CASE 
        WHEN ISNULL(rl.min_stock_level, 0) > cs.current_stock 
        THEN ISNULL(rl.min_stock_level, 0) - cs.current_stock 
        ELSE 0 
    END as shortage_quantity,
    
    CASE 
        WHEN ISNULL(rl.min_stock_level, 0) > 0 
        THEN CAST((cs.current_stock * 100.0 / rl.min_stock_level) AS DECIMAL(5,2))
        ELSE 0 
    END as stock_percentage,
    
    -- Priority (Critical First)
    CASE 
        WHEN cs.is_emergency = 1 AND cs.current_stock < ISNULL(rl.min_stock_level * 2, 0) THEN '1-EMERGENCY'
        WHEN cs.current_stock = 0 THEN '2-CRITICAL - OUT OF STOCK'
        WHEN cs.current_stock < 10 THEN '3-HIGH - VERY LOW'
        WHEN cs.current_stock < ISNULL(rl.min_stock_level, 0) THEN '4-MEDIUM - LOW STOCK'
        ELSE '5-NORMAL'
    END as alert_priority,
    
    -- Recommended Action
    CASE 
        WHEN cs.current_stock = 0 THEN 'URGENT - ORDER IMMEDIATELY'
        WHEN cs.current_stock < 10 THEN 'ORDER TODAY'
        WHEN cs.current_stock < ISNULL(rl.min_stock_level, 0) THEN 'ORDER THIS WEEK'
        ELSE 'MONITOR'
    END as recommended_action

FROM #current_stock_summary cs
LEFT JOIN reorder_levels rl 
    ON cs.medicine_id = rl.medicine_id

WHERE 
    cs.current_stock < ISNULL(rl.min_stock_level, 0)
    OR (cs.is_emergency = 1 AND cs.current_stock < ISNULL(rl.min_stock_level * 2, 0))

ORDER BY 
    alert_priority,
    cs.current_stock ASC;

PRINT '✅ Query 2 completed. Rows returned: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO


-- =============================================
-- QUERY 3: Expiry Alert - Next 30 Days
-- Database: stock_medcine_db
-- Tables: purchases_transactions, medicines_master
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 3: Expiry Alert...';
GO

-- Check if tables exist
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'purchases_transactions')
BEGIN
    PRINT '❌ ERROR: purchases_transactions table not found!';
    RETURN;
END
GO

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'medicines_master')
BEGIN
    PRINT '❌ ERROR: medicines_master table not found!';
    RETURN;
END
GO

SELECT 
    -- Medicine details
    ISNULL(m.medicine_name, 'Unknown') as medicine_name,
    ISNULL(m.category, 'Unknown') as category,
    ISNULL(m.manufacturer, 'Unknown') as manufacturer,
    
    -- Batch details
    ISNULL(p.batch_no, 'N/A') as batch_no,
    p.manufacturing_date,
    p.expiry_date,
    ISNULL(p.quantity_remaining, 0) as quantity_remaining,
    
    -- Financial impact
    ISNULL(p.purchase_price, 0) as purchase_price,
    ISNULL(p.selling_price, 0) as selling_price,
    ISNULL(p.quantity_remaining * p.purchase_price, 0) as total_cost_value,
    
    -- Time calculations
    DATEDIFF(day, GETDATE(), p.expiry_date) as days_until_expiry,
    
    -- Risk category
    CASE 
        WHEN p.expiry_date IS NULL THEN 'NO EXPIRY DATE'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 7 THEN 'CRITICAL - SELL NOW'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 15 THEN 'HIGH - URGENT'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 30 THEN 'MEDIUM - PLAN DISCOUNT'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) > 30 THEN 'LOW - SAFE'
        ELSE 'EXPIRED'
    END as expiry_risk,
    
    -- Recommended discount
    CASE 
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 7 THEN '50% DISCOUNT'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 15 THEN '30% DISCOUNT'
        WHEN DATEDIFF(day, GETDATE(), p.expiry_date) <= 30 THEN '20% DISCOUNT'
        ELSE 'NO DISCOUNT NEEDED'
    END as recommended_discount

FROM purchases_transactions p
LEFT JOIN medicines_master m 
    ON p.medicine_id = m.medicine_id

WHERE 
    p.expiry_date IS NOT NULL
    AND p.expiry_date BETWEEN GETDATE() AND DATEADD(day, 30, GETDATE())
    AND ISNULL(p.quantity_remaining, 0) > 0

ORDER BY 
    p.expiry_date ASC,
    p.quantity_remaining DESC;

PRINT '✅ Query 3 completed. Rows returned: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO


-- =============================================
-- QUERY 4: Stock Valuation by Category
-- Database: stock_medcine_db
-- Tables: purchases_transactions, medicines_master
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 4: Stock Valuation by Category...';
GO

-- Check if tables exist
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'purchases_transactions')
BEGIN
    PRINT '❌ ERROR: purchases_transactions table not found!';
    RETURN;
END
GO

-- Calculate total investment for percentage calculation
DECLARE @TotalInvestment DECIMAL(18,2);
SELECT @TotalInvestment = ISNULL(SUM(quantity_remaining * purchase_price), 1)
FROM purchases_transactions 
WHERE expiry_date > GETDATE() AND quantity_remaining > 0;
GO

SELECT 
    ISNULL(m.category, 'Uncategorized') as category,
    
    -- Counts
    COUNT(DISTINCT m.medicine_id) as unique_medicines,
    COUNT(DISTINCT p.batch_no) as total_batches,
    ISNULL(SUM(p.quantity_remaining), 0) as total_units_in_stock,
    
    -- Financial Summary
    ISNULL(SUM(p.quantity_remaining * p.purchase_price), 0) as total_investment,
    ISNULL(SUM(p.quantity_remaining * p.selling_price), 0) as total_potential_revenue,
    ISNULL(SUM(p.quantity_remaining * (p.selling_price - p.purchase_price)), 0) as total_expected_profit,
    
    -- Averages
    ISNULL(AVG(p.purchase_price), 0) as avg_purchase_price,
    ISNULL(AVG(p.selling_price), 0) as avg_selling_price,
    
    -- Margin Percentage (handle division by zero)
    CASE 
        WHEN AVG(ISNULL(p.purchase_price, 0)) > 0 
        THEN CAST(AVG((p.selling_price - p.purchase_price) / NULLIF(p.purchase_price, 0) * 100) AS DECIMAL(10,2))
        ELSE 0 
    END as avg_margin_percentage,
    
    -- Expiry Risk in this category
    ISNULL(SUM(CASE 
        WHEN p.expiry_date <= DATEADD(day, 30, GETDATE()) 
        THEN p.quantity_remaining * p.purchase_price 
        ELSE 0 
    END), 0) as at_risk_value_next_30_days,
    
    -- Percentage of total stock (handle division by zero)
    CASE 
        WHEN (SELECT ISNULL(SUM(quantity_remaining * purchase_price), 0) 
              FROM purchases_transactions 
              WHERE expiry_date > GETDATE()) > 0
        THEN CAST(ISNULL(SUM(p.quantity_remaining * p.purchase_price), 0) * 100.0 / 
            (SELECT ISNULL(SUM(quantity_remaining * purchase_price), 0) 
             FROM purchases_transactions 
             WHERE expiry_date > GETDATE()) AS DECIMAL(5,2))
        ELSE 0 
    END as percentage_of_total_value

FROM purchases_transactions p
LEFT JOIN medicines_master m 
    ON p.medicine_id = m.medicine_id

WHERE 
    p.expiry_date > GETDATE()
    AND p.quantity_remaining > 0

GROUP BY ISNULL(m.category, 'Uncategorized')
ORDER BY total_investment DESC;

PRINT '✅ Query 4 completed.';
GO



-- =============================================
-- QUERY 5: Emergency Medicines Status
-- Database: stock_medcine_db
-- Tables: medicines_master, purchases_transactions, reorder_levels
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 5: Emergency Medicines Report...';
GO

-- Check if temporary table exists
IF OBJECT_ID('tempdb..#current_stock_summary') IS NULL
BEGIN
    PRINT '❌ ERROR: #current_stock_summary table not found!';
    PRINT 'Please run Query 1 first.';
    RETURN;
END
GO

SELECT 
    -- Emergency medicine details
    cs.medicine_name,
    cs.category,
    cs.manufacturer,
    
    -- Stock status
    cs.current_stock,
    ISNULL(rl.min_stock_level, 30) as normal_minimum,
    ISNULL(rl.min_stock_level * 2, 60) as emergency_required_stock,
    
    -- Deficit calculation
    CASE 
        WHEN cs.current_stock >= ISNULL(rl.min_stock_level * 2, 60) THEN 0
        ELSE ISNULL(rl.min_stock_level * 2, 60) - cs.current_stock
    END as emergency_deficit,
    
    -- Status with colors
    CASE 
        WHEN cs.current_stock = 0 THEN '🔴 CRITICAL - OUT OF STOCK'
        WHEN cs.current_stock < ISNULL(rl.min_stock_level, 30) THEN '🟠 EMERGENCY - BELOW NORMAL'
        WHEN cs.current_stock < ISNULL(rl.min_stock_level * 2, 60) THEN '🟡 WARNING - BELOW EMERGENCY LEVEL'
        ELSE '🟢 ADEQUATE'
    END as emergency_status,
    
    -- Action required
    CASE 
        WHEN cs.current_stock < ISNULL(rl.min_stock_level * 2, 60) 
        THEN 'ORDER ' + CAST(ISNULL(rl.reorder_quantity, 50) AS VARCHAR) + ' UNITS NOW'
        ELSE 'NO ACTION NEEDED'
    END as action_required

FROM #current_stock_summary cs
LEFT JOIN reorder_levels rl 
    ON cs.medicine_id = rl.medicine_id

WHERE cs.is_emergency = 1

ORDER BY 
    CASE 
        WHEN cs.current_stock = 0 THEN 1
        WHEN cs.current_stock < ISNULL(rl.min_stock_level, 30) THEN 2
        WHEN cs.current_stock < ISNULL(rl.min_stock_level * 2, 60) THEN 3
        ELSE 4
    END;

PRINT '✅ Query 5 completed. Rows returned: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO


-- =============================================
-- QUERY 6: Sales Analysis - Last 30 Days
-- Database: stock_medcine_db
-- Tables: sales_transactions, medicines_master
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 6: Sales Analysis...';
GO

-- Check if tables exist
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'sales_transactions')
BEGIN
    PRINT '❌ ERROR: sales_transactions table not found!';
    RETURN;
END
GO

-- Medicine-wise Sales Performance
SELECT TOP 20
    ISNULL(m.medicine_name, 'Unknown') as medicine_name,
    ISNULL(m.category, 'Unknown') as category,
    ISNULL(m.manufacturer, 'Unknown') as manufacturer,
    ISNULL(m.is_emergency, 0) as is_emergency,
    
    -- Sales metrics
    ISNULL(SUM(s.quantity_sold), 0) as total_units_sold_30days,
    COUNT(DISTINCT s.sale_date) as days_sold,
    ISNULL(SUM(s.quantity_sold * s.selling_price), 0) as total_revenue_30days,
    
    -- Averages
    CASE 
        WHEN COUNT(s.sale_id) > 0 
        THEN CAST(AVG(s.quantity_sold * 1.0) AS DECIMAL(10,2))
        ELSE 0 
    END as avg_units_per_sale,
    
    CASE 
        WHEN 30 > 0 
        THEN CAST(ISNULL(SUM(s.quantity_sold), 0) / 30.0 AS DECIMAL(10,2))
        ELSE 0 
    END as avg_daily_sales,
    
    -- Classification
    CASE 
        WHEN ISNULL(SUM(s.quantity_sold), 0) / 30.0 > 10 THEN 'FAST MOVING'
        WHEN ISNULL(SUM(s.quantity_sold), 0) / 30.0 > 3 THEN 'NORMAL MOVING'
        WHEN ISNULL(SUM(s.quantity_sold), 0) / 30.0 > 1 THEN 'SLOW MOVING'
        ELSE 'VERY SLOW MOVING'
    END as movement_category

FROM sales_transactions s
LEFT JOIN medicines_master m 
    ON s.medicine_id = m.medicine_id

WHERE s.sale_date >= DATEADD(day, -30, GETDATE())

GROUP BY 
    m.medicine_name,
    m.category,
    m.manufacturer,
    m.is_emergency

ORDER BY total_units_sold_30days DESC;

PRINT '✅ Query 6 completed.';
GO


-- =============================================
-- QUERY 7: Supplier Performance Analysis
-- Database: stock_medcine_db
-- Tables: suppliers_master, purchases_transactions
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 7: Supplier Performance...';
GO

-- Check if tables exist
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'suppliers_master')
BEGIN
    PRINT '❌ ERROR: suppliers_master table not found!';
    RETURN;
END
GO

SELECT 
    ISNULL(s.supplier_name, 'Unknown') as supplier_name,
    ISNULL(s.city, 'Unknown') as city,
    ISNULL(s.lead_time_days, 0) as lead_time_days,
    
    -- Purchase summary
    COUNT(DISTINCT p.purchase_id) as total_purchase_orders,
    COUNT(DISTINCT p.medicine_id) as unique_medicines_supplied,
    ISNULL(SUM(p.quantity_purchased), 0) as total_units_purchased,
    ISNULL(SUM(p.quantity_purchased * p.purchase_price), 0) as total_purchase_value,
    
    -- Current stock from this supplier
    ISNULL(SUM(CASE 
        WHEN p.expiry_date > GETDATE() 
        THEN p.quantity_remaining 
        ELSE 0 
    END), 0) as current_stock_from_supplier,
    
    -- Expiry issues
    ISNULL(SUM(CASE 
        WHEN p.expiry_date <= DATEADD(day, 30, GETDATE()) 
        THEN p.quantity_remaining * p.purchase_price 
        ELSE 0 
    END), 0) as expiring_stock_value,
    
    -- Expiry percentage (quality indicator)
    CASE 
        WHEN ISNULL(SUM(p.quantity_purchased), 0) > 0 
        THEN CAST(
            (ISNULL(SUM(CASE WHEN p.expiry_date <= DATEADD(day, 30, GETDATE()) 
                        THEN p.quantity_purchased ELSE 0 END), 0) * 100.0 / 
            NULLIF(SUM(p.quantity_purchased), 0)) 
            AS DECIMAL(5,2))
        ELSE 0 
    END as percentage_expiring_soon

FROM suppliers_master s
LEFT JOIN purchases_transactions p 
    ON s.supplier_id = p.supplier_id

GROUP BY 
    s.supplier_name,
    s.city,
    s.lead_time_days

ORDER BY 
    percentage_expiring_soon ASC,
    total_purchase_value DESC;

PRINT '✅ Query 7 completed.';
GO


-- =============================================
-- QUERY 8: Executive Dashboard - All KPIs
-- Database: stock_medcine_db
-- Tables: All tables
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 8: Executive Dashboard...';
GO

-- Check if temporary table exists for low stock calculation
IF OBJECT_ID('tempdb..#current_stock_summary') IS NULL
BEGIN
    PRINT '⚠️ Warning: #current_stock_summary not found. Some metrics may be 0.';
END
GO

SELECT 
    -- SECTION 1: OVERALL STOCK HEALTH
    ISNULL((SELECT COUNT(*) FROM medicines_master), 0) as total_medicines,
    ISNULL((SELECT COUNT(*) FROM medicines_master WHERE is_emergency = 1), 0) as emergency_medicines,
    ISNULL((SELECT COUNT(DISTINCT medicine_id) FROM purchases_transactions WHERE expiry_date > GETDATE()), 0) as medicines_in_stock,
    
    -- SECTION 2: STOCK ALERTS
    ISNULL((
        SELECT COUNT(*) 
        FROM #current_stock_summary cs
        JOIN reorder_levels rl ON cs.medicine_id = rl.medicine_id
        WHERE cs.current_stock < rl.min_stock_level
    ), 0) as low_stock_count,
     
    ISNULL((SELECT COUNT(*) FROM #current_stock_summary WHERE current_stock = 0), 0) as out_of_stock_count,
    
    -- SECTION 3: EMERGENCY STATUS
    ISNULL((
        SELECT COUNT(*) 
        FROM #current_stock_summary cs
        JOIN reorder_levels rl ON cs.medicine_id = rl.medicine_id
        WHERE cs.is_emergency = 1 AND cs.current_stock < rl.min_stock_level * 2
    ), 0) as emergency_low_count,
    
    -- SECTION 4: EXPIRY RISK
    ISNULL((
        SELECT ISNULL(SUM(quantity_remaining * purchase_price), 0)
        FROM purchases_transactions 
        WHERE expiry_date BETWEEN GETDATE() AND DATEADD(day, 30, GETDATE())
    ), 0) as expiry_risk_value_30days,
     
    -- SECTION 5: FINANCIAL SUMMARY
    ISNULL((
        SELECT ISNULL(SUM(quantity_remaining * purchase_price), 0)
        FROM purchases_transactions WHERE expiry_date > GETDATE()
    ), 0) as total_investment,
     
    ISNULL((
        SELECT ISNULL(SUM(quantity_remaining * selling_price), 0)
        FROM purchases_transactions WHERE expiry_date > GETDATE()
    ), 0) as potential_revenue,
    
    -- SECTION 6: SALES SUMMARY
    ISNULL((
        SELECT ISNULL(SUM(quantity_sold), 0) 
        FROM sales_transactions WHERE sale_date >= DATEADD(day, -30, GETDATE())
    ), 0) as total_units_sold_30days,
     
    ISNULL((
        SELECT ISNULL(SUM(quantity_sold * selling_price), 0)
        FROM sales_transactions WHERE sale_date >= DATEADD(day, -30, GETDATE())
    ), 0) as total_revenue_30days;

PRINT '✅ Query 8 completed.';
GO


-- =============================================
-- QUERY 9: Clean Up Temporary Tables
-- Database: stock_medcine_db
-- =============================================

USE [stock_medcine db];
GO

PRINT '🧹 Starting Cleanup...';
GO

-- Drop temporary table if exists
IF OBJECT_ID('tempdb..#current_stock_summary') IS NOT NULL
BEGIN
    DROP TABLE #current_stock_summary;
    PRINT '✅ #current_stock_summary dropped';
END
ELSE
BEGIN
    PRINT '⚠️ #current_stock_summary not found';
END

-- Drop any other temporary tables you might have created
IF OBJECT_ID('tempdb..#stock_summary_temp') IS NOT NULL
    DROP TABLE #stock_summary_temp;

IF OBJECT_ID('tempdb..#expiry_temp') IS NOT NULL
    DROP TABLE #expiry_temp;

PRINT '✅ Cleanup completed!';
GO



-- =============================================
-- QUERY 10: Export Ready Data
-- For Excel and Power BI
-- Database: stock_medcine_db
-- =============================================

USE [stock_medcine db];
GO

PRINT '🚀 Starting Query 10: Export Data...';
GO

-- 1. Stock Status for Export
SELECT 
    m.medicine_id,
    m.medicine_name,
    m.category,
    m.is_emergency,
    ISNULL(SUM(p.quantity_remaining), 0) as current_stock,
    ISNULL(rl.min_stock_level, 0) as min_stock_level,
    ISNULL(rl.reorder_quantity, 0) as reorder_quantity,
    CASE 
        WHEN ISNULL(SUM(p.quantity_remaining), 0) < ISNULL(rl.min_stock_level, 0) THEN 'YES'
        ELSE 'NO'
    END as is_low_stock
FROM medicines_master m
LEFT JOIN purchases_transactions p 
    ON m.medicine_id = p.medicine_id AND p.expiry_date > GETDATE()
LEFT JOIN reorder_levels rl 
    ON m.medicine_id = rl.medicine_id
GROUP BY 
    m.medicine_id,
    m.medicine_name,
    m.category,
    m.is_emergency,
    rl.min_stock_level,
    rl.reorder_quantity
ORDER BY m.medicine_name;
GO

-- 2. Expiry Alert for Export
SELECT 
    ISNULL(m.medicine_name, 'Unknown') as medicine_name,
    p.batch_no,
    p.expiry_date,
    p.quantity_remaining,
    p.purchase_price,
    (p.quantity_remaining * p.purchase_price) as loss_if_expired,
    DATEDIFF(day, GETDATE(), p.expiry_date) as days_remaining
FROM purchases_transactions p
LEFT JOIN medicines_master m ON p.medicine_id = m.medicine_id
WHERE p.expiry_date > GETDATE()
    AND p.quantity_remaining > 0
ORDER BY p.expiry_date;
GO



USE [stock_medcine db];
GO

-- Ek simple query jo sab kaam ki hai
SELECT 
    'TOTAL MEDICINES' as Metric,
    COUNT(*) as Value 
FROM medicines_master
UNION ALL
SELECT 
    'LOW STOCK ITEMS',
    COUNT(*) 
FROM medicines_master m
JOIN reorder_levels r ON m.medicine_id = r.medicine_id
LEFT JOIN purchases_transactions p ON m.medicine_id = p.medicine_id
WHERE ISNULL(p.quantity_remaining, 0) < r.min_stock_level
UNION ALL
SELECT 
    'EXPIRING IN 30 DAYS',
    COUNT(*) 
FROM purchases_transactions 
WHERE expiry_date BETWEEN GETDATE() AND DATEADD(day, 30, GETDATE());
GO


USE [stock_medcine db];
GO

SELECT 
    m.medicine_name,
    m.category,
    m.is_emergency,
    ISNULL(SUM(p.quantity_remaining), 0) as current_stock,
    ISNULL(r.min_stock_level, 30) as min_stock_level
FROM medicines_master m
LEFT JOIN purchases_transactions p ON m.medicine_id = p.medicine_id AND p.expiry_date > GETDATE()
LEFT JOIN reorder_levels r ON m.medicine_id = r.medicine_id
GROUP BY m.medicine_name, m.category, m.is_emergency, r.min_stock_level
ORDER BY current_stock ASC;