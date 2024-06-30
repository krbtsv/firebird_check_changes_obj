set term ^ ;

create or alter procedure dbcc_check_changes(
    db type of column dbcc_changes_history.db
    , db_user varchar(32)= null
    , db_password varchar(8) = null
    , db_role varchar(32) = null
)
as
declare obj_type type of column dbcc_changes_history.obj_type;
declare obj_name type of column dbcc_changes_history.obj_name;
declare prev_create_statement type of column dbcc_changes_history.create_statement;
declare create_statement type of column dbcc_changes_history.create_statement;
declare checked type of column dbcc_changes_history.checked;
declare changed type of column dbcc_changes_history.changed;
declare get_objects_stmt varchar(1024);
begin
    for select
            trim(t) as obj_type
            , trim(s) as get_objects_stmt
        from (
            select 'procedure' as t
                    , 'select rdb$procedure_name from rdb$procedures where coalesce(rdb$system_flag, 0) = 0' as s
                from rdb$database union
            select 'table' as t
                    , 'select rdb$relation_name
                            from rdb$relations
                            where coalesce(rdb$system_flag, 0) = 0
                            and coalesce(rdb$relation_type, 0) = 0
                    ' as s
                from rdb$database union
            select 'trigger' as t
                    , 'select rdb$trigger_name
                            from rdb$triggers
                            where coalesce(rdb$system_flag, 0) = 0
                    ' as s
                from rdb$database
        )
        into obj_type, get_objects_stmt
    do
    begin
        for execute statement get_objects_stmt
            on external db as user db_user password db_password role db_role
            into obj_name
        do
        begin
            prev_create_statement = null;
            changed = null;
            checked = 'now';
            create_statement = null;

            execute statement
                ('select stmt from aux_get_create_statement(:obj_name)')
                (obj_name := :obj_name)
                on external db as user db_user password db_password role db_role
                into create_statement;

            select first 1
                    create_statement
                    , changed
                from dbcc_changes_history
                where db is not distinct from :db
                    and obj_type is not distinct from :obj_type
                    and obj_name is not distinct from :obj_name
                order by checked desc
                into prev_create_statement, changed;

            if (prev_create_statement is distinct from create_statement)
                then changed = checked;

            update or insert into dbcc_changes_history
                    (db, obj_type, obj_name, changed, checked, create_statement)
                values (:db, :obj_type, :obj_name, coalesce(:changed, :checked), :checked, :create_statement);
        end
    end
end^

set term ; ^