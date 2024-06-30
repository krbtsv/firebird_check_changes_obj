create or alter view dbcc_changes_summary as
	select
	    db, obj_type, obj_name
	    , count(*) changes_count
	    , max(changed) as last_changing
	    , max(checked) as last_checking
	    , min(checked) as first_checking
	from dbcc_changes_history
	group by db, obj_type, obj_name
	order by last_changing desc, db, obj_type, obj_name