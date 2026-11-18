-- Editable 30-vehicle model mix and a one-time starter job at Stations 6 and 1.
create function kanban_private.validate_config(p_config jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare c jsonb:=coalesce(p_config,'{"tCount":20,"aCount":10,"pattern":"TTATTA"}'::jsonb);
 t integer; a integer; pattern text; sequence text;
begin
 if jsonb_typeof(c)<>'object' or coalesce(c->>'tCount','')!~'^[0-9]+$'
    or coalesce(c->>'aCount','')!~'^[0-9]+$' then
   raise exception 'Use whole-number Model T and Model A quantities';
 end if;
 t:=(c->>'tCount')::integer; a:=(c->>'aCount')::integer;
 if t<0 or a<0 or t>30 or a>30 or t+a<>30 then
   raise exception 'The Model T and Model A quantities must total 30';
 end if;
 pattern:=upper(regexp_replace(coalesce(c->>'pattern',''),'[[:space:]]+','','g'));
 if length(pattern)<1 or length(pattern)>30 or pattern!~'^[TA]+$' then
   raise exception 'Use 1 to 30 letters, T or A, for the production pattern';
 end if;
 sequence:=left(repeat(pattern,30),30);
 if length(sequence)-length(replace(sequence,'T',''))<>t then
   raise exception 'The repeated pattern does not match the chosen Model T / Model A quantities';
 end if;
 return jsonb_build_object('tCount',t,'aCount',a,'pattern',pattern);
end;
$$;

create function kanban_private.fresh_with_config(p_config jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare c jsonb:=kanban_private.validate_config(p_config); orders jsonb:='[]';
 sequence text; t integer; spare_count integer; t_ordinal integer:=0;
 i integer; model text; has_spare boolean;
begin
 sequence:=left(repeat(c->>'pattern',30),30);
 t:=(c->>'tCount')::integer; spare_count:=least(8,t);
 for i in 1..30 loop
   model:=substr(sequence,i,1); has_spare:=false;
   if model='T' then
     t_ordinal:=t_ordinal+1;
     -- Spread up to eight options across T orders only, including custom mixes.
     has_spare:=(t_ordinal*spare_count)/t>((t_ordinal-1)*spare_count)/t;
   end if;
   orders:=orders||jsonb_build_array(jsonb_build_object('id','TM-'||lpad(i::text,3,'0'),
     'model',model,'spare',has_spare,'status','planned','option','none'));
 end loop;
 return jsonb_build_object('generation',gen_random_uuid(),'config',c,'orders',orders,
   'released',0,'start',null,'attack',false,'attackStart',null,'paused',0,
   'inventory','{"S1":{"A":8,"T":8},"S2":{"A":8,"T":8}}'::jsonb,
   'kanbans','[]'::jsonb,'nextK',1,'spares','[]'::jsonb,'events','[]'::jsonb,'completed',0);
end;
$$;

create or replace function kanban_private.fresh() returns jsonb
language sql volatile set search_path = '' as $$
 select kanban_private.fresh_with_config(null);
$$;

create or replace function kanban_private.production_action(
 p_room uuid, p_key uuid, p_action text default 'sync', p_request uuid default null,
 p_generation uuid default null, p_item text default null, p_config jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r kanban_private.rooms%rowtype; s jsonb; ms bigint;
 is_instructor boolean; i integer; idx integer; o jsonb; model text;
 stock integer; k integer; cell integer; kind text; detail text; assigned_view text; links jsonb;
begin
 select * into r from kanban_private.rooms where id=p_room for update;
 if not found or p_key is null then
   raise exception 'Room link is invalid or has been replaced. Ask your instructor for an assigned station link';
 end if;
 is_instructor := p_key=r.instructor_key;
 if not is_instructor then
   select view into assigned_view from kanban_private.station_access
   where room_id=p_room and access_key=p_key;
   if assigned_view is null then
     raise exception 'Room link is invalid or has been replaced. Ask your instructor for an assigned station link';
   end if;
   if p_action is distinct from 'sync' and p_action is distinct from (case assigned_view
      when 'Station 11' then 'complete11' when 'Station 6' then 'complete6'
      when 'Station 1' then 'complete1' when 'Spare Tire' then 'completeSpare' else 'sync' end) then
     raise exception 'This link is restricted to %',assigned_view;
   end if;
 end if;
 ms := floor(extract(epoch from clock_timestamp())*1000)::bigint;
 s := kanban_private.advance(r.state,ms);
 if p_action is null or p_action not in ('sync','configure','start','reset','attack','restore','complete11','complete6','complete1','completeSpare') then
   raise exception 'Unknown action';
 end if;
 if p_action<>'sync' and not (coalesce(p_request=any(r.receipts),false)) then
   if p_request is null then raise exception 'Missing request ID'; end if;
   if p_action in ('configure','start','reset','attack','restore') and not is_instructor then
     raise exception 'Instructor link required';
   end if;
   if p_generation is distinct from (s->>'generation')::uuid then
     raise exception 'The run was reset. Refresh before trying again';
   end if;
   if p_action='reset' then
     s := kanban_private.fresh_with_config(s->'config');
   elsif p_action='configure' then
     if s->>'start' is not null then raise exception 'Reset the run before changing its mix or pattern'; end if;
     if p_config is null then raise exception 'Choose a model mix and pattern'; end if;
     if kanban_private.validate_config(p_config) is distinct from s->'config' then
       o:=s->'events';
       s:=kanban_private.fresh_with_config(p_config);
       s:=jsonb_set(s,'{events}',o);
       s:=kanban_private.add_event(s,'CONFIG_SAVED',
         (s->'config'->>'tCount')||' T / '||(s->'config'->>'aCount')||' A; pattern '||(s->'config'->>'pattern'),ms);
     end if;
   elsif p_action='start' then
     if s->>'start' is not null then raise exception 'Run already started'; end if;
     if s->'config' is null then s:=kanban_private.fresh(); end if;
     s := jsonb_set(s,'{start}',to_jsonb(ms));
     s := jsonb_set(s,'{kanbans}',jsonb_build_array(
       jsonb_build_object('id','K1','cell',2,'model','T','status','open','startup',true),
       jsonb_build_object('id','K2','cell',1,'model','T','status','open','startup',true)));
     s := jsonb_set(s,'{nextK}','3');
     s := kanban_private.add_event(s,'STARTER_JOBS','One Model T starter at Station 6 and Station 1; paired initial replenishment',ms);
     s := kanban_private.add_event(s,'START','Timed run started',ms);
     s := kanban_private.advance(s,ms);
   elsif p_action='attack' then
     if s->>'start' is null or (s->>'attack')::boolean then raise exception 'Cannot trigger interruption now'; end if;
     s := jsonb_set(jsonb_set(s,'{attack}','true'),'{attackStart}',to_jsonb(ms));
     s := kanban_private.add_event(s,'CYBER_ATTACK','Simulated ransomware interruption',ms);
   elsif p_action='restore' then
     if (s->>'attack')::boolean then
       s := jsonb_set(s,'{paused}',to_jsonb((s->>'paused')::bigint+ms-(s->>'attackStart')::bigint));
       s := jsonb_set(jsonb_set(s,'{attack}','false'),'{attackStart}','null');
       s := kanban_private.add_event(s,'RESTORE','Production restored',ms);
     end if;
   else
     if s->>'start' is null or (s->>'attack')::boolean then raise exception 'Production is stopped or paused'; end if;
     idx := null;
     if p_action='complete11' then
       select ord::integer-1, val into idx,o from jsonb_array_elements(s->'orders') with ordinality as x(val,ord)
       where val->>'status'='released' order by ord limit 1;
     elsif p_action='completeSpare' then
       select ord::integer-1, val into idx,o from jsonb_array_elements(s->'spares') with ordinality as x(val,ord)
       where val->>'status'='open' order by ord limit 1;
     else
       cell := case when p_action='complete6' then 2 else 1 end;
       select ord::integer-1, val into idx,o from jsonb_array_elements(s->'kanbans') with ordinality as x(val,ord)
       where val->>'status'='open' and (val->>'cell')::integer=cell order by ord limit 1;
     end if;
     if idx is null then raise exception 'No open work at this station'; end if;
     if p_item is distinct from o->>'id' then raise exception 'This item was already completed. Review the next item'; end if;
     model := o->>'model';
     k := (s->>'nextK')::integer;
     if p_action='complete11' then
       stock := (s->'inventory'->'S2'->>model)::integer;
       if stock<=0 then raise exception 'Supermarket 2 stockout for Model %',model; end if;
       s := jsonb_set(s,array['inventory','S2',model],to_jsonb(stock-1));
       s := jsonb_set(s,array['orders',idx::text,'status'],'"complete"');
       s := jsonb_set(s,'{completed}',to_jsonb((s->>'completed')::integer+1));
       s := jsonb_set(s,'{kanbans}',(s->'kanbans')||jsonb_build_array(jsonb_build_object('id','K'||k,'cell',2,'model',model,'status','open')));
       s := jsonb_set(s,'{nextK}',to_jsonb(k+1));
       kind := 'ST11_WITHDRAW'; detail := (o->>'id')||' Model '||model||' -> Station 6 Kanban';
     elsif p_action='complete6' then
       stock := (s->'inventory'->'S1'->>model)::integer;
       if stock<=0 then raise exception 'Supermarket 1 stockout for Model %',model; end if;
       s := jsonb_set(s,array['inventory','S1',model],to_jsonb(stock-1));
       s := jsonb_set(s,array['inventory','S2',model],to_jsonb((s->'inventory'->'S2'->>model)::integer+1));
       s := jsonb_set(s,array['kanbans',idx::text,'status'],'"done"');
       if coalesce((o->>'startup')::boolean,false) then
         -- Station 1's initial job already covers this starter withdrawal.
         -- Do not issue a second upstream job before a pacemaker pull.
         kind := 'ST6_STARTER_COMPLETE';
         detail := (o->>'id')||' Model T starter -> Supermarket 2 replenished; Station 1 starter already assigned';
       else
         s := jsonb_set(s,'{kanbans}',(s->'kanbans')||jsonb_build_array(jsonb_build_object('id','K'||k,'cell',1,'model',model,'status','open')));
         s := jsonb_set(s,'{nextK}',to_jsonb(k+1));
         kind := 'ST6_WITHDRAW_AND_CELL2_REPLENISH'; detail := (o->>'id')||' Model '||model||' -> Station 1 Kanban; Supermarket 2 replenished';
       end if;
     elsif p_action='complete1' then
       s := jsonb_set(s,array['inventory','S1',model],to_jsonb((s->'inventory'->'S1'->>model)::integer+1));
       s := jsonb_set(s,array['kanbans',idx::text,'status'],'"done"');
       kind := 'ST1_REPLENISH'; detail := (o->>'id')||' Model '||model;
     else
       s := jsonb_set(s,array['spares',idx::text,'status'],'"done"');
       for i in 0..29 loop
         if s->'orders'->i->>'id'=o->>'id' then s:=jsonb_set(s,array['orders',i::text,'option'],'"ready"'); exit; end if;
       end loop;
       kind := 'SPARE_READY'; detail := o->>'id';
     end if;
     s := kanban_private.add_event(s,kind,detail,ms);
   end if;
   r.receipts := (array_prepend(p_request,r.receipts))[1:256];
 end if;
 if s is distinct from r.state then
   r.revision := r.revision+1;
   update kanban_private.rooms set state=s,revision=r.revision,receipts=r.receipts where id=p_room;
   -- Broadcast is a hint only. Receivers always fetch capability-checked state.
   -- A forged hint cannot change production or deliver executable content.
   begin
     perform realtime.send(jsonb_build_object('revision',r.revision),'changed','kanban:'||r.station_key,false);
   exception when others then
     null; -- The periodic snapshot refresh recovers a missed notification.
   end;
 elsif r.receipts is distinct from (select receipts from kanban_private.rooms where id=p_room) then
   update kanban_private.rooms set receipts=r.receipts where id=p_room;
 end if;
 if is_instructor then
   select jsonb_object_agg(view,access_key) into links
   from kanban_private.station_access where room_id=p_room;
 end if;
 return jsonb_build_object('state',case when is_instructor then s else kanban_private.station_snapshot(s,assigned_view) end,
   'revision',r.revision,'serverTime',ms,'role',case when is_instructor then 'instructor' else 'station' end,
   'allowedTab',assigned_view,'stationLinks',links,'broadcastKey',r.station_key);
end;
$$;


-- Preserve the old six-argument RPC for existing station bookmarks/loaded clients.
create or replace function kanban_private.room_action(
 p_room uuid,p_key uuid,p_action text default 'sync',p_request uuid default null,
 p_generation uuid default null,p_item text default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select kanban_private.production_action(p_room,p_key,p_action,p_request,p_generation,p_item,null);
$$;

create function public.kanban_production_action(
 p_room uuid,p_key uuid,p_action text default 'sync',p_request uuid default null,
 p_generation uuid default null,p_item text default null,p_config jsonb default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
 if p_room is distinct from kanban_private.active_session() then
   raise exception 'Open the permanent instructor or station link for this production line';
 end if;
 return kanban_private.production_action(p_room,p_key,p_action,p_request,p_generation,p_item,p_config);
end;
$$;

revoke all on function kanban_private.validate_config(jsonb) from public,anon,authenticated;
revoke all on function kanban_private.fresh_with_config(jsonb) from public,anon,authenticated;
revoke all on function kanban_private.production_action(uuid,uuid,text,uuid,uuid,text,jsonb) from public;
grant execute on function kanban_private.production_action(uuid,uuid,text,uuid,uuid,text,jsonb) to anon,authenticated;
revoke all on function public.kanban_production_action(uuid,uuid,text,uuid,uuid,text,jsonb) from public;
grant execute on function public.kanban_production_action(uuid,uuid,text,uuid,uuid,text,jsonb) to anon,authenticated;

-- Only update a stopped permanent session. A running production/history is preserved
-- exactly; Reset will create the corrected default mix when it has no saved config.
update kanban_private.rooms set
 state=jsonb_set(jsonb_set(state,'{config}',kanban_private.validate_config(null)),'{orders}',kanban_private.fresh()->'orders'),
 revision=revision+1
where id=kanban_private.active_session() and state->>'start' is null and state->'config' is null;
