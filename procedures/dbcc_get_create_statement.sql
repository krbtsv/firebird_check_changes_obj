set term ^ ;

create or alter procedure aux_get_create_statement(
    object_name_in varchar(31)
    , object_type_in smallint = null -- has the same values as RDB$DEPENDENCIES.RDB$DEPENDED_ON_TYPE
    , only_fields varchar(8192) = null -- if is null - add all fields, otherwise add only specified fields
    , create_dummy smallint = null -- 0 (default) - to create db-object "as is"; 1 - to create dummy version (for table: all fields as varchar; for procedures: without in/out params and body; for triggers: without body); 2 - the same as 1, but to create procedures with all in/out params
    , add_commit smallint = null -- 0 (default) - do not add `commit`; 1 - add `commit` after statement;
    , alter_mode smallint = null -- add (`=0`, default) or not (otherwise) modificator `or alter`  for creating statement of procedures and triggers
)
returns(
    stmt blob sub_type text
    , object_name varchar(31)
    , object_type smallint
    , object_type_name varchar(16)
    , relation_type type of column rdb$relations.rdb$relation_type
    , error_code bigint
    , error_text varchar(1024)
)
as
declare field_name varchar(31);
declare field_type varchar(128);
declare field_params varchar(4096);
declare constraint_name varchar(31);
declare extra_info varchar(255);
declare is_begin smallint;
declare repeater smallint;
declare rdb$field_type type of column rdb$fields.rdb$field_type;
-- constants
declare TYPE_TABLE type of column rdb$dependencies.rdb$dependent_type = 0;
declare TYPE_VIEW type of column rdb$dependencies.rdb$dependent_type = 1;
declare TYPE_TRIGGER type of column rdb$dependencies.rdb$dependent_type = 2;
-- declare TYPE_COMPUTED_COLUMN type of column rdb$dependencies.rdb$dependent_type = 3;
-- declare TYPE_CONSTRAINT type of column rdb$dependencies.rdb$dependent_type = 4;
declare TYPE_PROCEDURE type of column rdb$dependencies.rdb$dependent_type = 5;
-- declare TYPE_INDEX_EXPRESSION smallint = 6;
declare TYPE_EXCEPTION type of column rdb$dependencies.rdb$dependent_type = 7;
-- declare TYPE_USER type of column rdb$dependencies.rdb$dependent_type = 8;
declare TYPE_DOMAIN type of column rdb$dependencies.rdb$dependent_type = 9;
-- declare TYPE_INDEX type of column rdb$dependencies.rdb$dependent_type = 10;
declare TYPE_SEQUENCE type of column rdb$dependencies.rdb$dependent_type = 14;
-- declare TYPE_UDF type of column rdb$dependencies.rdb$dependent_type = 15;
-- declare TYPE_COLLATION type of column rdb$dependencies.rdb$dependent_type = 17;
declare TABLE_TYPE_SYS_OR_USER type of column rdb$relations.rdb$relation_type = 0; -- 0 - system or user-defined table
declare TABLE_TYPE_VIEW type of column rdb$relations.rdb$relation_type = 1; -- 1 - view
declare TABLE_TYPE_EXTERNAL type of column rdb$relations.rdb$relation_type = 2; -- 2 - external table
declare TABLE_TYPE_MONITORING type of column rdb$relations.rdb$relation_typE = 3; -- 3 - monitoring table
declare TABLE_TYPE_GTT_TRANSACTION_LVL type of column rdb$relations.rdb$relation_type = 4; -- 4 - connection-level GTT (PRESERVE ROWS)
declare TABLE_TYPE_GTT_CONNECTION_LVL type of column rdb$relations.rdb$relation_type = 5; -- 5 - transaction-level GTT (DELETE ROWS)
declare endl varchar(2) = '
';
begin
    error_code = 0;
    error_text = '';
    create_dummy = coalesce(create_dummy, 0);
    add_commit = coalesce(add_commit, 0);
    alter_mode = coalesce(alter_mode, 0);

    object_type = object_type_in;
    object_name = upper(trim(object_name_in));

    if (object_type is null) then
    begin
        object_type = case
            when exists(select rdb$trigger_name
                    from rdb$triggers
                    where rdb$trigger_name = :object_name)
                then TYPE_TRIGGER
            when exists(select rdb$procedure_name
                    from rdb$procedures
                    where rdb$package_name is null
                        and rdb$procedure_name = :object_name)
                then TYPE_PROCEDURE
            when exists(select RDB$FIELD_NAME
                    from RDB$FIELDS
                    where RDB$FIELD_NAME = :object_name)
                then TYPE_DOMAIN
            when exists(select rdb$exception_name
                    from rdb$exceptions
                    where rdb$exception_name = :object_name)
                then TYPE_EXCEPTION
            when exists(select rdb$generator_name
                    from rdb$generators
                    where rdb$generator_name = :object_name)
                then TYPE_SEQUENCE
            else (select decode(rdb$relation_type
                                , 1, :TYPE_VIEW
                                , :TYPE_TABLE)
                    from rdb$relations
                    where rdb$relation_name = :object_name
                        and coalesce(rdb$relation_type, :TYPE_TABLE) in (:TABLE_TYPE_SYS_OR_USER
                                                                            , :TABLE_TYPE_VIEW
                                                                            , :TABLE_TYPE_GTT_TRANSACTION_LVL
                                                                            , :TABLE_TYPE_GTT_CONNECTION_LVL))
            end;
    end

    if (object_type is null) then exit;

    object_type_name =  case object_type
                                when TYPE_TABLE then 'table'
                                when TYPE_VIEW then 'view'
                                when TYPE_TRIGGER then 'trigger'
                                -- when TYPE_COMPUTED_COLUMN then 'computed column'
                                -- when TYPE_CONSTRAINT then 'constraint'
                                when TYPE_PROCEDURE then 'procedure'
                                -- when TYPE_INDEX_EXPRESSION then 'index expression'
                                when TYPE_EXCEPTION then 'exception'
                                -- when TYPE_USER then 'user'
                                when TYPE_DOMAIN then 'domain'
                                -- when TYPE_INDEX then 'index'
                                when TYPE_SEQUENCE then 'sequence'
                                -- when TYPE_UDF then 'UDF'
                                -- when TYPE_COLLATION then 'collation'
                        end;

    if(object_type = TYPE_TABLE) then
    begin
        relation_type = (select rdb$relation_type
                            from rdb$relations
                            where rdb$relation_name = :object_name);

        stmt = 'create '
                || trim(iif(relation_type in (TABLE_TYPE_GTT_CONNECTION_LVL, TABLE_TYPE_GTT_TRANSACTION_LVL)
                            , 'global temporary table'
                            , 'table'))
                || ' ' || trim(object_name) || '(' || :endl;

        is_begin = 1;
        for select
                trim(f.rdb$field_name) as field_name
                , iif(:create_dummy > 0
                        , 'varchar(1024)'
                        , trim(iif(f.rdb$field_source starts with upper('RDB$')
                                            , decode(finfo.rdb$field_type
                                                    , 7, 'smallint'
                                                    , 8, 'integer'
                                                    , 10, 'float'
                                                    , 12, 'date'
                                                    , 13, 'time'
                                                    , 14, 'char'
                                                    , 16, 'bigint'
                                                    , 23, 'boolean'
                                                    , 27, 'double precision'
                                                    , 35, 'timestamp'
                                                    , 37, 'varchar'
                                                    , 261, 'blob')
                                            , f.rdb$field_source))
                            || trim(iif(f.rdb$field_source starts with upper('RDB$') and finfo.rdb$field_type in (14, 37) -- char/varchar
                                        , '(' || finfo.rdb$field_length || ')'
                                        , ''))
                ) as field_type
                , coalesce(trim(f.rdb$default_source), '')
                    || iif(coalesce(f.rdb$null_flag, 0) = 1, ' not null', '') as field_params
            from rdb$relation_fields as f
                left join rdb$fields as finfo on finfo.rdb$field_name = f.rdb$field_source
            where f.rdb$relation_name = :object_name
                and (
                    :only_fields is null
                    or (',' || :only_fields || ',') like ('%,' || trim(f.rdb$field_name) || ',%') -- or field exists in table dependencies
                        or exists(select f.rdb$field_name -- or field is a part of primary key
                                    from rdb$relation_constraints as c
                                        inner join rdb$index_segments as idxs on idxs.rdb$index_name = c.rdb$index_name
                                    where c.rdb$relation_name = :object_name
                                        and c.rdb$constraint_type containing 'primary key'
                                        and idxs.rdb$field_name = f.rdb$field_name)
                    )
            order by f.rdb$field_position asc
            into field_name, field_type, field_params
        do
        begin
            stmt = stmt
                || iif(is_begin > 0, '', '    , ')
                || field_name || ' ' || trim(field_type) || ' ' || trim(field_params) || endl;
            is_begin = 0;
        end
        if (row_count = 0) then exit;

        is_begin = 1;
        for select
                trim(c.rdb$constraint_name) as constraint_name
                , trim(idxs.rdb$field_name) as field_name
            from rdb$relation_constraints as c
                inner join rdb$indices as idx on idx.rdb$index_name = c.rdb$index_name
                inner join rdb$index_segments as idxs on idxs.rdb$index_name = idx.rdb$index_name
            where c.rdb$relation_name = :object_name
                and c.rdb$constraint_type containing 'primary key'
            order by idxs.rdb$field_position
            into constraint_name, field_name
        do
        begin
            stmt = stmt
                || iif(is_begin > 0
                        , '    , constraint ' || constraint_name || ' primary key ('
                        , '    , ')
                || field_name;
            is_begin = 0;
        end
        if (row_count > 0) then stmt = stmt || ')' || endl;
        stmt = stmt || ')'
                    || case relation_type
                            when TABLE_TYPE_GTT_TRANSACTION_LVL
                                then ' ON COMMIT DELETE ROWS'
                            when TABLE_TYPE_GTT_CONNECTION_LVL
                                then ' ON COMMIT PRESERVE ROWS'
                            else ''
                        end
                    || ';';
    end
    else if(object_type = TYPE_VIEW) then
    begin
        stmt = 'create view ' || trim(object_name) || endl
            || ' as ' || endl
            || (select rdb$view_source from rdb$relations where rdb$relation_name = :object_name)
            || ';';
    end
    else if(object_type = TYPE_TRIGGER) then
    begin
        select
                ' for '  || rdb$relation_name || :endl
                || trim(iif(coalesce(rdb$trigger_inactive, 0) > 0, 'inactive', 'active'))
                -- from https://github.com/FirebirdSQL/firebird/blob/799bca3ca5f9eb604433addc0f2b7cb3b6c07275/doc/sql.extensions/README.universal_triggers
                -- // that's how trigger action types are encoded
                /*
                bit 0 = TRIGGER_BEFORE/TRIGGER_AFTER flag,
                bits 1-2 = TRIGGER_INSERT/TRIGGER_UPDATE/TRIGGER_DELETE (slot #1),
                bits 3-4 = TRIGGER_INSERT/TRIGGER_UPDATE/TRIGGER_DELETE (slot #2),
                bits 5-6 = TRIGGER_INSERT/TRIGGER_UPDATE/TRIGGER_DELETE (slot #3),
                and finally the above calculated value is decremented

                example #1:
                    TRIGGER_AFTER_DELETE =
                    = ((TRIGGER_DELETE << 1) | TRIGGER_AFTER) - 1 =
                    = ((3 << 1) | 1) - 1 =
                    = 0x00000110 (6)

                example #2:
                    TRIGGER_BEFORE_INSERT_UPDATE =
                    = ((TRIGGER_UPDATE << 3) | (TRIGGER_INSERT << 1) | TRIGGER_BEFORE) - 1 =
                    = ((2 << 3) | (1 << 1) | 0) - 1 =
                    = 0x00010001 (17)

                example #3:
                    TRIGGER_AFTER_UPDATE_DELETE_INSERT =
                    = ((TRIGGER_INSERT << 5) | (TRIGGER_DELETE << 3) | (TRIGGER_UPDATE << 1) | TRIGGER_AFTER) - 1 =
                    = ((1 << 5) | (3 << 3) | (2 << 1) | 1) - 1 =
                    = 0x00111100 (60)
                */
                || ' ' || trim(decode(bin_and(rdb$trigger_type + 1, 1), 0, 'before', 'after')
                                || ' ' || decode(bin_and(bin_shr(rdb$trigger_type + 1, 1), 3), 1, 'insert', 2, 'update', 3, 'delete')
                                || coalesce(' or ' || decode(bin_and(bin_shr(rdb$trigger_type + 1, 3), 3), 1, 'insert', 2, 'update', 3, 'delete'), '')
                                || coalesce(' or ' || decode(bin_and(bin_shr(rdb$trigger_type + 1, 5), 3), 1, 'insert', 2, 'update', 3, 'delete'), ''))
                || ' position ' || rdb$trigger_sequence
            from rdb$triggers
            where rdb$trigger_name = :object_name
                and coalesce(rdb$system_flag, 0) = 0
            into extra_info;

        if (row_count = 0 or extra_info is null) then exit;

        stmt = 'set term ^ ;' || endl
            || 'create ' || trim(iif(alter_mode > 0, 'or alter', '')) || ' trigger ' || trim(:object_name) ||  extra_info || endl
            || iif(create_dummy > 0 -- skipped
                    , 'as' || endl || 'begin' || endl || 'end'
                    , (select rdb$trigger_source from rdb$triggers where rdb$trigger_name = :object_name)
                )
            || '^' || endl
            || 'set term ; ^';
    end
    else if(object_type = TYPE_PROCEDURE) then
    begin
        if (not exists(select rdb$procedure_name
                        from rdb$procedures
                        where rdb$package_name is null
                            and rdb$procedure_name = :object_name
                            and coalesce(rdb$system_flag, 0) = 0)) then exit;

        stmt = 'set term ^ ;' || endl
                || 'create ' || trim(iif(alter_mode > 0, 'or alter', '')) || ' procedure ' || trim(:object_name);

        repeater = 0;
        while (repeater < 2) do
        begin
            is_begin = 1;
            for select
                    trim(rdb$parameter_name)
                    , finfo.rdb$field_type
                    , coalesce('type of column ' || trim(p.rdb$relation_name) || '.' || trim(p.rdb$field_name)
                                , trim(iif(p.rdb$field_source starts with upper('RDB$')
                                            , decode(finfo.rdb$field_type
                                                        , 7, 'smallint'
                                                        , 8, 'integer'
                                                        , 10, 'float'
                                                        , 12, 'date'
                                                        , 13, 'time'
                                                        , 14, 'char'
                                                        , 16, 'bigint'
                                                        , 23, 'boolean'
                                                        , 27, 'double precision'
                                                        , 35, 'timestamp'
                                                        , 37, 'varchar'
                                                        , 261, 'blob')
                                            , p.rdb$field_source))
                                    || trim(iif(p.rdb$field_source starts with upper('RDB$') and finfo.rdb$field_type in (14, 37)
                                                , '(' || finfo.rdb$field_length || ')'
                                                , ''))
                    ) as field_type
                    , coalesce(' ' || trim(coalesce(p.rdb$default_source, finfo.rdb$default_source)), '') as field_params
                from rdb$procedure_parameters as p
                    left join rdb$fields as finfo on finfo.rdb$field_name = p.rdb$field_source
                where p.rdb$package_name is null
                    and p.rdb$procedure_name = :object_name
                    and (:create_dummy in (0, 2)
                        -- for skipped only dummy params with dependencies
                        or (:create_dummy = 1 and (',' || :only_fields || ',') like ('%,' || trim(p.rdb$parameter_name) || ',%')))
                    and rdb$parameter_type = :repeater -- 0 - input param, 1 - output param
                order by p.rdb$parameter_number
                into field_name, rdb$field_type, field_type, field_params
            do
            begin
                stmt = stmt
                    || iif(is_begin > 0
                            , iif(repeater = 1, endl || 'returns', '') || '(' || endl || '    '
                            , '    , ')
                    || field_name || ' ' || field_type || ' ' || field_params || endl;
                is_begin = 0;
                if (field_type is null) then
                begin
                    error_code = 1;
                    error_text = 'unsupported field type rdb$field_type=' || coalesce(rdb$field_type, 'null')
                                    || ' for field ' || coalesce(field_name, 'null');
                    stmt = null;
                    suspend; exit;
                end
            end
            if (row_count > 0) then stmt = stmt || ')';

            repeater = repeater + 1;
        end

        stmt = stmt || endl
            || 'as' || endl
            || iif(create_dummy > 0 -- skipped
                    , 'begin' || endl
                        || iif(stmt containing 'returns(', 'suspend;', '') || endl
                        || 'end'
                    , (select rdb$procedure_source from rdb$procedures where rdb$package_name is null and rdb$procedure_name = :object_name)
                )
            || '^' || endl
            || 'set term ; ^';
    end
    else if(object_type = TYPE_EXCEPTION) then
    begin
        stmt = 'create exception ' || trim(object_name)
            || ' '''
            || (select rdb$message from rdb$exceptions where rdb$exception_name = :object_name)
            || ''';';
    end
    else if(object_type = TYPE_DOMAIN) then
    begin
        stmt = 'create domain ' || trim(object_name)
            || ' as '
            || trim((select
                        trim(decode(finfo.rdb$field_type
                                    , 7, 'smallint'
                                    , 8, 'integer'
                                    , 10, 'float'
                                    , 12, 'date'
                                    , 13, 'time'
                                    , 14, 'char'
                                    , 16, 'bigint'
                                    , 23, 'boolean'
                                    , 27, 'double precision'
                                    , 35, 'timestamp'
                                    , 37, 'varchar'
                                    , 261, 'blob'))
                            || trim(iif(finfo.rdb$field_type in (14, 37)
                                                    , '(' || finfo.rdb$field_length || ')'
                                                    , ''))
                            || coalesce(' ' || trim(finfo.rdb$default_source), '')
                            || iif(coalesce(finfo.rdb$null_flag, 0) = 1, ' not null', '')
                    from rdb$fields as finfo
                    where finfo.rdb$field_name = :object_name
                    ))
            || ';';
    end
    else if(object_type = TYPE_SEQUENCE) then
    begin
        stmt = 'create sequence ' || trim(object_name) || ';' || endl
                || iif(add_commit = 2, 'commit;' || endl, '');
    end

    stmt = stmt || endl;

    if (add_commit > 0) then
    begin
        stmt = stmt || 'commit;' || endl;
    end

    suspend;
end^

set term ; ^