/* BATCH PREPARATION: defines batches B1-B3 and creates the fictional LAB records.
   The real Olist rows are not copied here: etl.usp_ExtractBatch takes them from src
   by the purchase-date range of the batch (start inclusive, end exclusive).
   The values are fixed, so the same inputs are rebuilt after every reset.
   LAB records are test data only. They are not real business data.
   The X1 records are created later by 16_run_X1.sql.                              */
USE OlistDW_Project;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
DELETE FROM lab.Customers           WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.Orders              WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.OrderItems          WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.Products            WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.Sellers             WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.CategoryTranslation WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.Payments            WHERE BatchID IN (1, 2, 3);
DELETE FROM lab.Reviews             WHERE BatchID IN (1, 2, 3);
DELETE FROM etl.Batch               WHERE BatchID IN (1, 2, 3);

INSERT etl.Batch (BatchID, BatchName, PurchaseFrom, PurchaseTo, Description) VALUES
 (1, 'B1', '2017-01-01', '2018-01-01', N'Initial full load: orders purchased in 2017 + initial LAB records'),
 (2, 'B2', '2018-01-01', '2018-07-01', N'Incremental: 2018-01 to 2018-06 + SCD Type 0, 1 and 2 changes'),
 (3, 'B3', '2018-07-01', '2018-09-01', N'Incremental: 2018-07 to 2018-08 + late LAB order + LAB correction');

/* ---------- B1: initial LAB records ---------- */
INSERT lab.CategoryTranslation (product_category_name, product_category_name_english, BatchID, ChangeSeq, Operation)
VALUES (N'lab_training', N'Traning', 1, 1001, 'insert');          -- spelling mistake on purpose

INSERT lab.Sellers (seller_id, seller_city, seller_state, original_seller_state, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_SELLER_01', N'sao paulo', N'SP', N'SP', 1, 1002, 'insert');

INSERT lab.Products (product_id, product_category_name, product_weight_g, product_length_cm, product_height_cm, product_width_cm,
                     BatchID, ChangeSeq, Operation)
VALUES (N'LAB_PRODUCT_01', N'lab_training', N'1000', N'10', N'10', N'10', 1, 1003, 'insert');

INSERT lab.Customers (customer_id, customer_unique_id, customer_city, customer_state, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_CUST_01', N'LAB_CUSTOMER_01', N'sao paulo', N'SP', 1, 1004, 'insert');

INSERT lab.Orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                   order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
                   BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_01', N'LAB_CUST_01', N'delivered', N'2017-06-10 10:00:00', N'2017-06-10 11:00:00',
        N'2017-06-11 10:00:00', N'2017-06-15 10:00:00', N'2017-06-16 10:00:00', 1, 1005, 'insert');

INSERT lab.OrderItems (order_id, order_item_id, product_id, seller_id, price, freight_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_01', N'1', N'LAB_PRODUCT_01', N'LAB_SELLER_01', N'100.00', N'10.00', 1, 1006, 'insert');

INSERT lab.Payments (order_id, payment_sequential, payment_type, payment_installments, payment_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_01', N'1', N'credit_card', N'1', N'110.00', 1, 1007, 'insert');

INSERT lab.Reviews (review_id, order_id, review_score, review_creation_date, review_answer_timestamp, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_REVIEW_01', N'LAB_ORDER_01', N'4', N'2017-06-16 10:00:00', N'2017-06-16 10:00:00', 1, 1008, 'insert');

/* ---------- B2: SCD changes + LAB_ORDER_02 ---------- */
-- Type 1: correct the English category label.
INSERT lab.CategoryTranslation (product_category_name, product_category_name_english, BatchID, ChangeSeq, Operation)
VALUES (N'lab_training', N'Training', 2, 2001, 'update');

-- Type 2: the seller moves to Rio de Janeiro. Type 0: the same record tries to change the original state.
INSERT lab.Sellers (seller_id, seller_city, seller_state, original_seller_state, BatchID, ChangeSeq, Operation, EffectiveAt)
VALUES (N'LAB_SELLER_01', N'rio de janeiro', N'RJ', N'RJ', 2, 2002, 'update', '2018-01-01 00:00:00');

INSERT lab.Products (product_id, product_category_name, product_weight_g, product_length_cm, product_height_cm, product_width_cm,
                     BatchID, ChangeSeq, Operation)
VALUES (N'LAB_PRODUCT_02', N'lab_training', N'2000', N'10', N'10', N'10', 2, 2003, 'insert');

INSERT lab.Customers (customer_id, customer_unique_id, customer_city, customer_state, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_CUST_02', N'LAB_CUSTOMER_01', N'sao paulo', N'SP', 2, 2004, 'insert');

INSERT lab.Orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                   order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
                   BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_02', N'LAB_CUST_02', N'delivered', N'2018-02-10 10:00:00', N'2018-02-10 11:00:00',
        N'2018-02-11 10:00:00', N'2018-02-15 10:00:00', N'2018-02-14 10:00:00', 2, 2005, 'insert');

INSERT lab.OrderItems (order_id, order_item_id, product_id, seller_id, price, freight_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_02', N'1', N'LAB_PRODUCT_02', N'LAB_SELLER_01', N'200.00', N'20.00', 2, 2006, 'insert');

INSERT lab.Payments (order_id, payment_sequential, payment_type, payment_installments, payment_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_02', N'1', N'credit_card', N'1', N'220.00', 2, 2007, 'insert');

INSERT lab.Reviews (review_id, order_id, review_score, review_creation_date, review_answer_timestamp, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_REVIEW_02', N'LAB_ORDER_02', N'2', N'2018-02-16 10:00:00', N'2018-02-16 10:00:00', 2, 2008, 'insert');

/* ---------- B3: late order (purchased in 2017) + correction of LAB_ORDER_01 ---------- */
INSERT lab.Customers (customer_id, customer_unique_id, customer_city, customer_state, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_CUST_03', N'LAB_CUSTOMER_01', N'sao paulo', N'SP', 3, 3001, 'insert');

INSERT lab.Orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                   order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
                   BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_03', N'LAB_CUST_03', N'delivered', N'2017-11-10 10:00:00', N'2017-11-10 11:00:00',
        N'2017-11-11 10:00:00', N'2017-11-15 10:00:00', N'2017-11-16 10:00:00', 3, 3002, 'insert');

INSERT lab.OrderItems (order_id, order_item_id, product_id, seller_id, price, freight_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_03', N'1', N'LAB_PRODUCT_01', N'LAB_SELLER_01', N'300.00', N'30.00', 3, 3003, 'insert'),
       (N'LAB_ORDER_01', N'1', N'LAB_PRODUCT_01', N'LAB_SELLER_01', N'110.00', N'10.00', 3, 3004, 'update');

INSERT lab.Payments (order_id, payment_sequential, payment_type, payment_installments, payment_value, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_ORDER_03', N'1', N'credit_card', N'1', N'330.00', 3, 3005, 'insert'),
       (N'LAB_ORDER_01', N'1', N'credit_card', N'1', N'120.00', 3, 3006, 'update');

INSERT lab.Reviews (review_id, order_id, review_score, review_creation_date, review_answer_timestamp, BatchID, ChangeSeq, Operation)
VALUES (N'LAB_REVIEW_03', N'LAB_ORDER_03', N'5', N'2017-11-16 10:00:00', N'2017-11-16 10:00:00', 3, 3007, 'insert');

SELECT BatchID, BatchName, PurchaseFrom, PurchaseTo, Description FROM etl.Batch ORDER BY BatchID;
GO
