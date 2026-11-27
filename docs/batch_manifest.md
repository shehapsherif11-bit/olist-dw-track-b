# Batch manifest

The manifest is the view `etl.vwBatchManifest`: batch, table, source key, operation, change sequence,
effective time and test flag for every record received. The export is
[results/20_batch_manifest.txt](../results/20_batch_manifest.txt).

## Batches

| Batch | Real Olist orders (purchase date) | LAB changes |
|---|---|---|
| B1 | 2017-01-01 to 2017-12-31 | initial LAB seller, product, category, customer, `LAB_ORDER_01` |
| B2 | 2018-01-01 to 2018-06-30 | `LAB_PRODUCT_02`, `LAB_ORDER_02`, category correction (Type 1), seller relocation (Type 2), original-state overwrite attempt (Type 0) |
| B3 | 2018-07-01 to 2018-08-31 | late `LAB_ORDER_03` (purchased 2017-11-10), `LAB_ORDER_01` price 100 to 110 and payment 110 to 120 |
| X1 | none | `LAB_ORDER_X1`, purchased 2017-12-10, price 50, freight 5 |

## Rules

- `ChangeSeq` = BatchID*1000+n for an explicit LAB change, BatchID*1000 for a copied record.
- `Operation` = `insert` the first time a key is delivered, `update` when it was delivered before.
- A copied record (`ChangeSeq` ending in 000) carries the latest state up to that batch.

## Values chosen by the team for X1

The brief gives the price, freight and purchase time. The other values follow the brief's date offsets.

| Field | Value |
|---|---|
| Order, customer_id | `LAB_ORDER_X1`, `LAB_CUST_X1` (person `LAB_CUSTOMER_01`, sao paulo, SP) |
| Item | 1, `LAB_PRODUCT_01`, `LAB_SELLER_01` |
| Purchase, approval, carrier | 2017-12-10 10:00, 11:00, 2017-12-11 10:00 |
| Delivered, estimated | 2017-12-15 10:00, 2017-12-16 10:00 |
| Payment | sequence 1, credit_card, 1 installment, 55.00 |
| Review | `LAB_REVIEW_X1`, score 4 (chosen by the team), 2017-12-16 10:00 |

## Extra technical source columns

`BatchID`, `ChangeSeq`, `Operation`, `EffectiveAt` on every `lab` table, and `original_seller_state` on `lab.Sellers`.
