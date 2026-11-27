/* RESET: deletes the project database only, so the project can run again from empty.
   WARNING: all data in OlistDW_Project is lost. The CSV files are not touched. */
USE master;
GO
IF DB_ID(N'OlistDW_Project') IS NOT NULL
BEGIN
    ALTER DATABASE OlistDW_Project SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OlistDW_Project;
END;
GO
