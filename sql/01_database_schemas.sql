/* Creates the project database and its schemas. Run once after 00_reset.sql. */
USE master;
GO
CREATE DATABASE OlistDW_Project;
GO
-- SIMPLE recovery keeps the transaction log small. This is a classroom database.
ALTER DATABASE OlistDW_Project SET RECOVERY SIMPLE;
GO
USE OlistDW_Project;
GO
CREATE SCHEMA src;    -- unchanged copy of the CSV files
GO
CREATE SCHEMA lab;    -- LAB test source: ordered change records
GO
CREATE SCHEMA stg;    -- records received in each batch
GO
CREATE SCHEMA dw;     -- star schema: dimensions and facts
GO
CREATE SCHEMA sf;     -- small snowflake alternative
GO
CREATE SCHEMA mart;   -- reporting views
GO
CREATE SCHEMA etl;    -- load control, logs and procedures
GO
