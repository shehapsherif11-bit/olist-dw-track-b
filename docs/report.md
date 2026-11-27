# Report - Olist Data Warehouse, Track B (Products and categories)

## 1. Use case

A product manager wants to compare product and category performance month by month.
The warehouse loads Olist orders purchased from 2017-01-01 to 2018-08-31 and answers three questions.
All amounts are in BRL. **Sales** = sum of item prices of delivered orders. Sales exclude freight and are not profit.

## 2. Design choices

| Choice | Reason |
|---|---|
| Star schema with `FactSales` and five dimensions | Simple joins for reporting |
| `FactProductMonth` (product, month, test flag) | Monthly product summaries; recomputed, never added to |
| Category distinct orders counted from `FactSales` | Product order counts cannot be added |
| SCD Type 2 on seller location, Type 1 on category label, Type 0 on original seller state | Required history behaviour |
| Stored procedures started manually | No extra tools are needed |
| One transaction per batch and a last-successful-batch marker | A failed batch can be retried safely |
| `UPDATE` then `INSERT` instead of `MERGE` | Easier to read and explain |
| Snowflake in schema `sf`, reusing `ProductKey` | Small working alternative |

Details: [design.md](design.md) and [data_dictionary.md](data_dictionary.md).

## 3. Load results (real Olist data)

| Batch | FactSales rows | Sales | Freight | Source = warehouse = independent reference |
|---|---|---|---|---|
| B1 | 49,556 | 5,962,902.01 | 958,633.23 | yes |
| B2 | 46,219 | 5,511,595.02 | 926,690.83 | yes |
| B3 | 14,105 | 1,706,530.10 | 306,768.82 | yes |
| Total | 109,880 | 13,181,027.13 | 2,192,092.88 | yes |

- 96,211 delivered orders. 60,640 real product-month rows.
- Orders with another status are staged but not loaded into `FactSales`: shipped 1,097, unavailable 602, canceled 580, processing 299, invoiced 296, created 5, approved 2.
- No real row was rejected. No fact uses an unknown member.
- Warnings: two category codes have no English translation (`pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos`). The code is used as the label.
- 1,535 delivered items (170,660.74) belong to products without a category. They appear as `Unknown`.

Evidence: [T2_reconciliation.txt](../results/T2_reconciliation.txt), [T4_integrity.txt](../results/T4_integrity.txt).

## 4. OLAP outputs

All five operations are in `sql/18_olap.sql`. Full output: [18_olap.txt](../results/18_olap.txt).

| Operation | Level of detail |
|---|---|
| Roll-up | month, summed up to quarter, year and grand total (`GROUP BY ROLLUP`; `GROUPING()` marks subtotal rows) |
| Drill-down | year, then quarter, then month for 2017 |
| Slice | category, with one fixed year (2017) |
| Dice | month x category x delivery state, with filters on several dimensions |
| Pivot | category as rows, month as columns, year 2017 (`PIVOT`) |

**Roll-up** (month rows are in the output file)

| Quarter | Sales | Delivered orders |
|---|---|---|
| 2017 Q1 | 705,220.61 | 4,949 |
| 2017 Q2 | 1,251,931.30 | 8,984 |
| 2017 Q3 | 1,643,703.89 | 12,215 |
| 2017 Q4 | 2,362,046.21 | 17,280 |
| **2017** | **5,962,902.01** | **43,428** |
| 2018 Q1 | 2,704,438.38 | 20,627 |
| 2018 Q2 | 2,807,156.64 | 19,646 |
| 2018 Q3 (July and August) | 1,706,530.10 | 12,510 |
| **2018** | **7,218,125.12** | **52,783** |
| **Grand total** | **13,181,027.13** | **96,211** |

- **Drill-down:** 2017 = sum of its quarters = sum of its months = 5,962,902.01.
- **Slice** (year 2017, by category): the largest are `bed_bath_table` 490,596.92, `watches_gifts` 475,610.71 and `health_beauty` 473,833.00.

**Dice** (2017 and 2018, January and February, two categories, delivery states SP and RJ)

| Year | Month | Category | State | Sales | Orders |
|---|---|---|---|---|---|
| 2017 | 1 | computers_accessories | RJ | 99.00 | 1 |
| 2017 | 1 | computers_accessories | SP | 1,068.94 | 10 |
| 2017 | 1 | health_beauty | RJ | 646.40 | 7 |
| 2017 | 1 | health_beauty | SP | 3,079.36 | 28 |
| 2017 | 2 | computers_accessories | RJ | 1,300.51 | 12 |
| 2017 | 2 | computers_accessories | SP | 3,262.44 | 36 |
| 2017 | 2 | health_beauty | RJ | 3,633.02 | 17 |
| 2017 | 2 | health_beauty | SP | 6,519.37 | 58 |
| 2018 | 1 | computers_accessories | RJ | 10,975.13 | 85 |
| 2018 | 1 | computers_accessories | SP | 33,418.76 | 232 |
| 2018 | 1 | health_beauty | RJ | 6,362.36 | 60 |
| 2018 | 1 | health_beauty | SP | 27,908.08 | 256 |

**Pivot** (2017; five categories and six months shown; NULL in the full output means no sale)

| Category | Jan | Feb | Mar | Oct | Nov | Dec |
|---|---|---|---|---|---|---|
| bed_bath_table | 3,804.36 | 15,572.13 | 25,120.02 | 46,007.70 | 87,957.63 | 50,081.16 |
| watches_gifts | 8,086.52 | 10,992.39 | 24,892.38 | 64,874.63 | 95,292.34 | 69,556.92 |
| health_beauty | 12,366.44 | 22,059.92 | 25,652.45 | 40,698.99 | 78,274.40 | 60,688.75 |
| sports_leisure | 9,212.14 | 15,629.98 | 25,472.89 | 48,568.98 | 62,686.24 | 58,722.48 |
| computers_accessories | 3,924.14 | 11,319.09 | 28,078.80 | 42,009.38 | 69,676.32 | 37,428.67 |

**Star versus snowflake:** the category-sales results are equal (0 different rows). The Type 1 label correction is stored on product rows in the star and on one category row in the snowflake. Speed was not measured. Evidence: [19_snowflake_compare.txt](../results/19_snowflake_compare.txt).

## 5. Business questions (Track B)

Evidence: [17_track_b_queries.txt](../results/17_track_b_queries.txt).

### Q1. Which categories contribute most to monthly sales?

| Category | Sales, whole period | Share | Months in the top 5 (of 20) |
|---|---|---|---|
| health_beauty | 1,229,557.50 | 9.33% | 19 |
| watches_gifts | 1,163,465.91 | 8.83% | 17 |
| bed_bath_table | 1,022,955.77 | 7.76% | 19 |
| sports_leisure | 952,840.40 | 7.23% | 19 |
| computers_accessories | 888,055.59 | 6.74% | 10 |

**Finding:** these five categories hold about 40% of sales. The monthly leader changes: `health_beauty` led 6 months, `watches_gifts` 5, `bed_bath_table` 4.

### Q2. Which products have the largest share of sales inside their category?

- In the three largest categories the leading product has a small share: `health_beauty` 5.17% (2,380 products), `watches_gifts` 3.22%, `bed_bath_table` 4.11%.
- Among categories with at least 100 products, the highest leading shares are `fixed_telephony` 24.61% and `home_confort` 24.53%.
- Shares above 50% appear only in very small categories (1 to 9 products), for example `cds_dvds_musicals` 100% with one product.

**Finding:** large categories do not depend on one product. A high share in a very small category says little.

### Q3. Which categories gained or lost sales between matching periods?

January-August 2018 against January-August 2017: total sales went from 2,993,456.13 to 7,218,125.12 (+141.1%).
57 categories gained, 14 lost, and 3 had no 2017 base.

| Largest gains | Change | % | Largest losses | Change | % |
|---|---|---|---|---|---|
| health_beauty | +512,202.80 | +210.33 | market_place | -7,523.36 | -49.86 |
| watches_gifts | +486,717.34 | +241.98 | tablets_printing_image | -3,889.79 | -75.42 |
| sports_leisure | +300,441.93 | +138.63 | fashion_male_clothing | -2,342.41 | -50.44 |
| computers_accessories | +281,638.03 | +131.22 | dvds_blu_ray | -1,863.08 | -62.19 |
| bed_bath_table | +277,914.03 | +109.22 | fashio_female_clothing | -931.04 | -60.16 |

**Finding:** growth is broad. The losses are small in value compared with the gains. Large percentages often come from a small 2017 base.

## 6. Limitations

- Only delivered orders are counted. Orders near the end of the data may not be delivered yet, so August 2018 can be lower than the final value.
- The data describes what happened. It does not explain why sales changed.
- No cost data: profit cannot be calculated.
- Category labels come from the source and include spelling variants (for example `home_confort` and `home_comfort_2`). They were not merged.
- Deleted records and reversed deliveries are not handled.
- Seller city text contains source errors.

## 7. Synthetic test results (not business findings)

These records are fictional (`LAB_`, `IsTestData = 1`). They only test the loads. The seller relocation is simulated.

| After | Fact rows | Sales | Freight | Seller versions | Sales by seller state SP / RJ | Payments |
|---|---|---|---|---|---|---|
| B1 | 1 | 100 | 10 | 1 | 100 / 0 | 110 |
| B2 | 2 | 300 | 30 | 2 | 100 / 200 | 330 |
| B3 | 3 | 610 | 60 | 2 | 410 / 200 | 670 |
| Replay B3 | 3 | 610 | 60 | 2 | 410 / 200 | 670 |
| X1 | 4 | 660 | 65 | 2 | 460 / 200 | 725 |
| Replay X1 | 4 | 660 | 65 | 2 | 460 / 200 | 725 |

Actual results equal these expected values ([13](../results/13_run_B1.txt), [14](../results/14_run_B2.txt), [15](../results/15_run_B3_replay.txt), [16](../results/16_run_X1.txt)).

- Type 0: the attempt to change the original state to RJ was ignored and logged.
- Type 1: `Traning` became `Training` without a new `ProductKey`.
- Type 2: a second seller row starts on 2018-01-01. The late 2017 order uses the SP version.
- A simulated failure in B2 was rolled back completely, and the retry succeeded.
- Replays changed 0 rows.
- X1: December 2017 gained 50 sales, 5 freight and 1 item, once.
- Bad test rows were rejected and then rolled back ([T5](../results/T5_negative_dq.txt)).

## 8. Member contributions

| Member | Contribution |
|---|---|
| Shehap Sherif EL-Batanouny | ETL and warehouse loads (lead): stored procedures, batches B1 to B3, SCD handling, reset and rebuild |
| Ahmed Hossam | Schema design and diagrams: star and snowflake schemas, data dictionary, source-to-target mapping |
| Abdulmalek Mahmoud | Marts, OLAP and queries: mart views, FactProductMonth, OLAP operations, Track B questions |
| Rohiam Tamer | Tests, report and repository: test scripts T1 to T5, synthetic checks, report, GitHub repository |
