create table dbcc_changes_history(
    db varchar(255)
    , obj_type varchar(16) -- table, procedure, trigger, view
    , obj_name varchar(31)
    , changed timestamp
    , checked timestamp
    , create_statement blob sub_type text
    , constraint pk_mds_dbcc_entity_history primary key (db, obj_type, obj_name, changed)
);

create desc index idx_dbcc_changes_history on dbcc_changes_history (checked);
create asc index idx_dbcc_changes_history_name on dbcc_changes_history (obj_name);