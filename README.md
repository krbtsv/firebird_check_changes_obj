# Database objects check changes monitoring tools

This solution allows you to keep the change history of database objects (procedures, triggers, tables)
in another separate database.

<!-- MarkdownTOC autolink="true" lowercase="all" uri_encoding="false" -->

- [How it works](#how-it-works)
- [Setup](#setup)
- [Using](#using)

<!-- /MarkdownTOC -->


## How it works

You create special database (`DBCC`) to storing history of changes,
which contains:

- table [DBCC_CHANGES_HISTORY][] for stroing changes
- procedure [DBCC_CHECK_CHANGES][] to check changes in specified database
(information about database for check passed into procedure parameters)
- view [DBCC_CHANGES_SUMMARY][] to display the change history in convenient view
and periodicaly run procedure in that procedure

After that you run procedure [DBCC_CHECK_CHANGES][] in `DBCC`
with specifying access parameters to checked database.
That procedure compares current create statement (made by [DBCC_GET_CREATE_STATEMENT][])
for each object in checked database with last stored in `DBCC` create statement of the same object
and if has differents it storing new version into [DBCC_CHANGES_HISTORY][]

You can also choose not to use a separate database (`DBCC`) for storing history of changes in monitored database,
instead you can create required objects directly in monitored database and run [DBCC_CHECK_CHANGES][] in it.


## Setup

- Create new database `DBCC` to store the change history, for example by follow command (for Windows cmd.exe):
    ```cmd
    echo create database 'C:\DB\DBCC.FDB' page_size 16384 default character set win1251; commit; | isql -user SYSDBA
    ```
- Init `DBCC` (create structure) by creating required objects:
    - [DBCC_CHANGES_HISTORY][] - table for storing the history of changes
    (for example by command: `isql -user SYSDBA C:\DB\DBCC.FDB -ch utf8 -i tbl_dbcc_changes_history.sql`)
    - [DBCC_CHECK_CHANGES][] - procedure to run process of checking target db for changes
    and store its into [DBCC_CHANGES_HISTORY][] table
    - [DBCC_CHANGES_SUMMARY][] - view to see the change history in convenient view
- Add procedure [DBCC_GET_CREATE_STATEMENT][] into target database which you want to check for changes


## Using

- Create bash/batch script to run regulary checking for changes (in batch for windows remove double quotes `"`).
    ```cmd
    echo "execute procedure dbcc_check_changes('127.0.0.1:db_to_check', 'SYSDBA', 'masterkey');" | isql -user SYSDBA C:\DB\DBCC.FDB
    ```
- Add that script to scheduler (for example, into `crontab` for unix)


[DBCC_CHANGES_HISTORY]: tables/dbcc_changes_history.sql
[DBCC_CHECK_CHANGES]: procedures/dbcc_check_changes.sql
[DBCC_CHANGES_SUMMARY]: views/dbcc_changes_summary.sql
[DBCC_GET_CREATE_STATEMENT]: procedures/dbcc_get_create_statement.sql