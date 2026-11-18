-- New, random fixtures only; never touches an existing room. Every fixture rolls back.
begin;
do $$
declare s jsonb; a jsonb; b jsonb; snap jsonb; c jsonb; plan jsonb;
 r kanban_private.rooms%rowtype; g uuid; req uuid; k11 uuid; k6 uuid; k1 uuid; kt uuid;
 minutes integer; total integer; t integer; n integer; i integer; interval_ms bigint;
 now_ms bigint:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
 item text; seq text; before_keys text;
begin
 for minutes in select unnest(array[40,20]) loop
   plan:=kanban_private.run_plan(minutes); total:=(plan->>'totalOrders')::integer;
   interval_ms:=(plan->>'intervalSeconds')::bigint*1000;
   c:=case when minutes=20 then '{"runMinutes":20,"tCount":11,"aCount":4,"pattern":"TTAT TATT TATT ATT"}'::jsonb else null end;
   s:=kanban_private.fresh_with_config(c);
   select string_agg(o->>'model','' order by ord) into seq from jsonb_array_elements(s->'orders') with ordinality x(o,ord);
   if seq<>(case when minutes=20 then 'TTATTATTTATTATT' else repeat('TTATTA',5) end) then raise exception 'Default sequence failed for %',minutes; end if;
   if jsonb_array_length(s->'orders')<>total then raise exception 'Incorrect total'; end if;
   for t in 0..total loop
     a:=kanban_private.fresh_with_config(jsonb_build_object('runMinutes',minutes,'tCount',t,'aCount',total-t,'pattern',repeat('T',t)||repeat('A',total-t)));
     if (select count(*) from jsonb_array_elements(a->'orders') o where o->>'model'='T')<>t then raise exception 'Mix failed'; end if;
     if (select count(*) from jsonb_array_elements(a->'orders') o where (o->>'spare')::boolean)<>least((plan->>'spareCount')::integer,t) then raise exception 'Spare count failed'; end if;
     if exists(select 1 from jsonb_array_elements(a->'orders') o where (o->>'spare')::boolean and o->>'model'<>'T') then raise exception 'Spare on A'; end if;
   end loop;
   s:=jsonb_set(s,'{start}',to_jsonb(now_ms));
   a:=kanban_private.advance(s,now_ms);
   if (select count(*) from jsonb_array_elements(a->'orders') o where o->>'status'='released')<>(plan->>'batchSize')::integer then raise exception 'Initial release failed'; end if;
   for i in 1..(plan->>'batchCount')::integer-1 loop
     a:=kanban_private.advance(s,now_ms+i*interval_ms-1);
     if (a->>'released')::integer<>i then raise exception 'Early release'; end if;
     a:=kanban_private.advance(s,now_ms+i*interval_ms);
     if (a->>'released')::integer<>i+1 then raise exception 'Boundary release failed'; end if;
     n:=least(total,(i+1)*(plan->>'batchSize')::integer);
     if (select count(*) from jsonb_array_elements(a->'orders') o where o->>'status'='released')<>n then raise exception 'Batch count wrong'; end if;
   end loop;
   a:=kanban_private.advance(s,now_ms+minutes*60000+900000);
   if jsonb_array_length(a->'orders')<>total or (a->>'released')::integer<>(plan->>'batchCount')::integer then raise exception 'Extra orders after run target'; end if;
   if kanban_private.advance(a,now_ms+minutes*60000+900000)<>a then raise exception 'Duplicate release'; end if;
   b:=jsonb_set(jsonb_set(s,'{attack}','true'),'{attackStart}',to_jsonb(now_ms+1000));
   if kanban_private.advance(b,now_ms+interval_ms*2)<>b then raise exception 'Paused run advanced'; end if;
   b:=jsonb_set(s,'{paused}','60000');
   if kanban_private.advance(b,now_ms+interval_ms+59999)->>'released'<>'1' or kanban_private.advance(b,now_ms+interval_ms+60000)->>'released'<>'2' then raise exception 'Pause compensation failed'; end if;
   snap:=kanban_private.station_snapshot(s,'Station 6');
   if snap->'schedule'<>plan or snap->'orders'<>'[]'::jsonb or snap ? 'config' then raise exception 'Station metadata or privacy failed'; end if;
 end loop;
 -- Validate legacy configs and active states still keep their 40-minute schedule.
 s:=kanban_private.fresh_with_config('{"tCount":20,"aCount":10,"pattern":"TTATTA"}');
 if s->'config'->>'runMinutes'<>'40' then raise exception 'Legacy config compatibility failed'; end if;
 s:=jsonb_set(s-'config'-'schedule','{start}',to_jsonb(now_ms));
 if kanban_private.advance(s,now_ms+479999)->>'released'<>'1' or kanban_private.advance(s,now_ms+480000)->>'released'<>'2' then raise exception 'Legacy timing changed'; end if;
 begin
   perform kanban_private.validate_config('{"runMinutes":10,"tCount":11,"aCount":4,"pattern":"TTAT"}');
   raise exception 'Invalid duration accepted';
 exception when raise_exception then if SQLERRM not like 'Choose a 20-minute%' then raise; end if; end;
 begin
   perform kanban_private.validate_config('{"runMinutes":20,"tCount":20,"aCount":10,"pattern":"TTATTA"}');
   raise exception 'Wrong total accepted';
 exception when raise_exception then if SQLERRM not like 'The Model T and Model A quantities must total 15%' then raise; end if; end;
 -- Complete a full short run through capability-checked actions on a new fixture.
 insert into kanban_private.rooms(id,instructor_key,station_key) values(gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) returning * into r;
 perform kanban_private.ensure_station_access(r.id);
 select access_key into k11 from kanban_private.station_access where room_id=r.id and view='Station 11';
 select access_key into k6 from kanban_private.station_access where room_id=r.id and view='Station 6';
 select access_key into k1 from kanban_private.station_access where room_id=r.id and view='Station 1';
 select access_key into kt from kanban_private.station_access where room_id=r.id and view='Spare Tire';
 select md5(jsonb_object_agg(view,access_key)::text) into before_keys from kanban_private.station_access where room_id=r.id;
 g:=(r.state->>'generation')::uuid; req:=gen_random_uuid();
 c:='{"runMinutes":20,"tCount":11,"aCount":4,"pattern":"TTATTATTTATTATT"}';
 a:=kanban_private.production_action(r.id,r.instructor_key,'configure',req,g,null,c);
 b:=kanban_private.production_action(r.id,r.instructor_key,'configure',req,g,null,c);
 if a->>'revision'<>b->>'revision' then raise exception 'Configure duplicate'; end if;
 g:=(a->'state'->>'generation')::uuid;
 a:=kanban_private.production_action(r.id,r.instructor_key,'start',gen_random_uuid(),g);
 if jsonb_array_length(a->'state'->'kanbans')<>2 or a->'state'->>'released'<>'1' or a->'state'->>'completed'<>'0' then raise exception 'Short startup failed'; end if;
 a:=kanban_private.room_action(r.id,k6,'complete6',gen_random_uuid(),g,'K1');
 a:=kanban_private.room_action(r.id,k1,'complete1',gen_random_uuid(),g,'K2');
 if jsonb_array_length(a->'state'->'kanbans')<>0 then raise exception 'Duplicate startup pull'; end if;
 begin
   perform kanban_private.production_action(r.id,r.instructor_key,'configure',gen_random_uuid(),g,null,null);
   raise exception 'Changed active run';
 exception when raise_exception then if SQLERRM not like 'Reset the run before changing%' then raise; end if; end;
 -- Time travel only this newly inserted fixture, never any production record.
 update kanban_private.rooms set state=jsonb_set(state,'{start}',to_jsonb(now_ms-900000)) where id=r.id;
 a:=kanban_private.room_action(r.id,r.instructor_key);
 if jsonb_array_length(a->'state'->'spares')<>4 then raise exception 'Short spare release failed'; end if;
 for i in 1..4 loop
   select o->>'id' into item from jsonb_array_elements(a->'state'->'spares') o where o->>'status'='open' limit 1;
   perform kanban_private.room_action(r.id,kt,'completeSpare',gen_random_uuid(),g,item);
   a:=kanban_private.room_action(r.id,r.instructor_key);
 end loop;
 for i in 1..15 loop
   perform kanban_private.room_action(r.id,k11,'complete11',gen_random_uuid(),g,'TM-'||lpad(i::text,3,'0'));
   a:=kanban_private.room_action(r.id,k6);
   item:=a->'state'->'kanbans'->0->>'id';
   perform kanban_private.room_action(r.id,k6,'complete6',gen_random_uuid(),g,item);
   a:=kanban_private.room_action(r.id,k1);
   item:=a->'state'->'kanbans'->0->>'id';
   perform kanban_private.room_action(r.id,k1,'complete1',gen_random_uuid(),g,item);
 end loop;
 a:=kanban_private.room_action(r.id,r.instructor_key);
 if a->'state'->>'completed'<>'15' or exists(select 1 from jsonb_array_elements(a->'state'->'kanbans') k where k->>'status'='open') then raise exception 'Full short pull chain failed'; end if;
 if exists(select 1 from jsonb_array_elements(a->'state'->'orders') o where (o->>'spare')::boolean and o->>'option'<>'ready') then raise exception 'Short spare completion failed'; end if;
 a:=kanban_private.room_action(r.id,r.instructor_key,'reset',gen_random_uuid(),g);
 if a->'state'->'config'<>c then raise exception 'Reset lost short settings'; end if;
 if before_keys<>(select md5(jsonb_object_agg(view,access_key)::text) from kanban_private.station_access where room_id=r.id) then raise exception 'Links changed'; end if;
end $$;
rollback;
select 'PASS: exact 40/20-minute defaults; all 47 mixes; release boundaries; 4/4/4/3 final batch; no extra releases; pause compensation; legacy timing; station metadata/privacy; rejected invalid settings; full 15-order pull chain; four spare completions; paired starters; idempotency; saved duration on reset; stable links. Isolated fixture rolled back.' as result;
