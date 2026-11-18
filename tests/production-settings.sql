-- Uses a newly inserted, transaction-local fixture only. No existing production record is modified.
begin;
do $$
declare s jsonb; a jsonb; b jsonb; r kanban_private.rooms%rowtype;
 t integer; seq text; g uuid; request_id uuid:=gen_random_uuid();
 k11 uuid; k6 uuid; k1 uuid; old_keys text; item text;
begin
 s:=kanban_private.fresh();
 select string_agg(o->>'model','' order by n) into seq
 from jsonb_array_elements(s->'orders') with ordinality x(o,n);
 if seq<>repeat('TTATTA',5) or s->'config'<>'{"tCount":20,"aCount":10,"pattern":"TTATTA"}'::jsonb then
   raise exception 'Default 20T:10A TTATTA schedule failed';
 end if;
 for t in 0..30 loop
   s:=kanban_private.fresh_with_config(jsonb_build_object('tCount',t,'aCount',30-t,'pattern',repeat('T',t)||repeat('A',30-t)));
   if (select count(*) from jsonb_array_elements(s->'orders') o where o->>'model'='T')<>t then raise exception 'Incorrect custom mix %',t; end if;
   if (select count(*) from jsonb_array_elements(s->'orders') o where (o->>'spare')::boolean)<>least(8,t) then raise exception 'Incorrect spare count %',t; end if;
   if exists(select 1 from jsonb_array_elements(s->'orders') o where (o->>'spare')::boolean and o->>'model'<>'T') then raise exception 'Spare assigned to A'; end if;
 end loop;
 begin
   perform kanban_private.validate_config('{"tCount":20,"aCount":10,"pattern":"TATATA"}');
   raise exception 'Mismatched pattern was accepted';
 exception when raise_exception then if SQLERRM not like 'The repeated pattern does not match%' then raise; end if; end;
 begin
   perform kanban_private.validate_config('{"tCount":20,"aCount":10,"pattern":"TBT"}');
   raise exception 'Invalid pattern letters accepted';
 exception when raise_exception then if SQLERRM not like 'Use 1 to 30 letters%' then raise; end if; end;

 insert into kanban_private.rooms(id,instructor_key,station_key)
 values(gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) returning * into r;
 perform kanban_private.ensure_station_access(r.id);
 select access_key into k11 from kanban_private.station_access where room_id=r.id and view='Station 11';
 select access_key into k6 from kanban_private.station_access where room_id=r.id and view='Station 6';
 select access_key into k1 from kanban_private.station_access where room_id=r.id and view='Station 1';
 select md5(jsonb_object_agg(view,access_key)::text) into old_keys from kanban_private.station_access where room_id=r.id;
 -- Only this new fixture is accessed by the mutating test calls below.
 a:=kanban_private.room_action(r.id,r.instructor_key);g:=(a->'state'->>'generation')::uuid;
 a:=kanban_private.production_action(r.id,r.instructor_key,'configure',request_id,g,null,'{"tCount":10,"aCount":20,"pattern":"TAATAA"}');
 b:=kanban_private.production_action(r.id,r.instructor_key,'configure',request_id,g,null,'{"tCount":10,"aCount":20,"pattern":"TAATAA"}');
 if a->'state'->>'generation'<>b->'state'->>'generation' or a->>'revision'<>b->>'revision' then raise exception 'Configure retry was not idempotent'; end if;
 g:=(a->'state'->>'generation')::uuid;
 a:=kanban_private.production_action(r.id,r.instructor_key,'reset',gen_random_uuid(),g);
 if a->'state'->'config'<>'{"tCount":10,"aCount":20,"pattern":"TAATAA"}'::jsonb then raise exception 'Reset lost chosen settings'; end if;
 g:=(a->'state'->>'generation')::uuid;
 begin
   perform kanban_private.production_action(r.id,k6,'configure',gen_random_uuid(),g,null,'{"tCount":20,"aCount":10,"pattern":"TTATTA"}');
   raise exception 'Station configured the mix';
 exception when raise_exception then if SQLERRM not like 'This link is restricted%' then raise; end if; end;
 -- Use the old RPC too: already-loaded station/instructor clients get the new startup behavior.
 a:=kanban_private.room_action(r.id,r.instructor_key,'start',gen_random_uuid(),g);
 if jsonb_array_length(a->'state'->'kanbans')<>2 or a->'state'->>'completed'<>'0' then raise exception 'Starter jobs missing or counted as vehicles'; end if;
 if exists(select 1 from jsonb_array_elements(a->'state'->'kanbans') k where k->>'model'<>'T' or not (k->>'startup')::boolean) then raise exception 'Incorrect starter model'; end if;
 a:=kanban_private.room_action(r.id,k1,'complete1',gen_random_uuid(),g,'K2');
 a:=kanban_private.room_action(r.id,k6,'complete6',gen_random_uuid(),g,'K1');
 if exists(select 1 from jsonb_array_elements(a->'state'->'kanbans') k where k->>'status'='open') then raise exception 'Starter completion caused extra pull before pacemaker'; end if;
 b:=kanban_private.room_action(r.id,r.instructor_key);
 if b->'state'->'inventory'->'S1'->>'T'<>'8' or b->'state'->'inventory'->'S2'->>'T'<>'9' then raise exception 'Starter inventory accounting failed'; end if;
 a:=kanban_private.room_action(r.id,k11,'complete11',gen_random_uuid(),g,'TM-001');
 a:=kanban_private.room_action(r.id,k6,'complete6',gen_random_uuid(),g,'K3');
 a:=kanban_private.room_action(r.id,k1,'complete1',gen_random_uuid(),g,'K4');
 begin
   perform kanban_private.production_action(r.id,r.instructor_key,'configure',gen_random_uuid(),g,null,'{"tCount":20,"aCount":10,"pattern":"TTATTA"}');
   raise exception 'Active run was reconfigured';
 exception when raise_exception then if SQLERRM not like 'Reset the run before changing%' then raise; end if; end;
 -- Repeat with Station 6's initial job finishing before Station 1's.
 a:=kanban_private.room_action(r.id,r.instructor_key,'reset',gen_random_uuid(),g);g:=(a->'state'->>'generation')::uuid;
 a:=kanban_private.room_action(r.id,r.instructor_key,'start',gen_random_uuid(),g);
 a:=kanban_private.room_action(r.id,k6,'complete6',gen_random_uuid(),g,'K1');
 a:=kanban_private.room_action(r.id,k1,'complete1',gen_random_uuid(),g,'K2');
 if exists(select 1 from jsonb_array_elements(a->'state'->'kanbans') k where k->>'status'='open') then raise exception 'Starter order dependence detected'; end if;
 if old_keys<>(select md5(jsonb_object_agg(view,access_key)::text) from kanban_private.station_access where room_id=r.id) then raise exception 'Access keys changed'; end if;
end $$;
rollback;
select 'Passed: default TTATTA; all 31 possible mixes; T-only spare options; invalid settings rejected; configuration retry deduplication; settings retained on reset; permissions; active-run protection; one starter per station in either completion order; normal pull chain; stable links. Only isolated fixture writes occurred; all were rolled back.' as result;
