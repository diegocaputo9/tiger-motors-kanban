-- Apply only in the destination Kanban project. No source project changes.
create table kanban_private.station_access (
  room_id uuid not null references kanban_private.rooms(id) on delete cascade,
  view text not null check (view in ('Station 11','Station 6','Station 1','Spare Tire','Heijunka','Inventory','History')),
  access_key uuid not null default gen_random_uuid() unique,
  primary key(room_id,view)
);
alter table kanban_private.station_access enable row level security;
revoke all on kanban_private.station_access from public,anon,authenticated;

create function kanban_private.ensure_station_access(p_room uuid) returns void
language sql set search_path = '' as $$
 insert into kanban_private.station_access(room_id,view)
 select p_room,v from unnest(array['Station 11','Station 6','Station 1','Spare Tire','Heijunka','Inventory','History']) v
 on conflict(room_id,view) do nothing;
$$;

-- Each station receives only the data used by its assigned screen, plus the
-- common production-clock and interruption fields. It never receives other keys.
create function kanban_private.station_snapshot(s jsonb, view text) returns jsonb
language sql immutable set search_path = '' as $$
 select jsonb_build_object(
   'generation',s->'generation','start',s->'start','attack',s->'attack',
   'attackStart',s->'attackStart','paused',s->'paused','released',s->'released',
   'orders',case when view='Heijunka' then s->'orders' when view='Station 11' then
     (select coalesce(jsonb_agg(o),'[]'::jsonb) from jsonb_array_elements(s->'orders') o where o->>'status'='released') else '[]'::jsonb end,
   'kanbans',case when view in ('Station 1','Station 6') then
     (select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_array_elements(s->'kanbans') k
      where (k->>'cell')::integer=case when view='Station 6' then 2 else 1 end and k->>'status'='open') else '[]'::jsonb end,
   'spares',case when view='Spare Tire' then s->'spares' else '[]'::jsonb end,
   'inventory',case when view='Inventory' then s->'inventory' else '{}'::jsonb end,
   'events',case when view='History' then s->'events' else '[]'::jsonb end
 );
$$;

select kanban_private.ensure_station_access(id) from kanban_private.rooms;

create or replace function kanban_private.create_room(p_room uuid, p_instructor uuid, p_station uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if p_room is null or p_instructor is null or p_station is null or p_instructor=p_station then
   raise exception 'Invalid room keys';
 end if;
 insert into kanban_private.rooms(id,instructor_key,station_key)
 values(p_room,p_instructor,p_station) on conflict(id) do nothing;
 if not exists(select 1 from kanban_private.rooms where id=p_room and instructor_key=p_instructor and station_key=p_station) then
   raise exception 'Room already exists';
 end if;
 perform kanban_private.ensure_station_access(p_room);
 return jsonb_build_object('room',p_room);
end;
$$;

create or replace function kanban_private.room_action(
 p_room uuid, p_key uuid, p_action text default 'sync', p_request uuid default null,
 p_generation uuid default null, p_item text default null)
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
 if p_action is null or p_action not in ('sync','start','reset','attack','restore','complete11','complete6','complete1','completeSpare') then
   raise exception 'Unknown action';
 end if;
 if p_action<>'sync' and not (coalesce(p_request=any(r.receipts),false)) then
   if p_request is null then raise exception 'Missing request ID'; end if;
   if p_action in ('start','reset','attack','restore') and not is_instructor then
     raise exception 'Instructor link required';
   end if;
   if p_generation is distinct from (s->>'generation')::uuid then
     raise exception 'The run was reset. Refresh before trying again';
   end if;
   if p_action='reset' then
     s := kanban_private.fresh();
   elsif p_action='start' then
     if s->>'start' is not null then raise exception 'Run already started'; end if;
     s := jsonb_set(s,'{start}',to_jsonb(ms));
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
       s := jsonb_set(s,'{kanbans}',(s->'kanbans')||jsonb_build_array(jsonb_build_object('id','K'||k,'cell',1,'model',model,'status','open')));
       s := jsonb_set(s,'{nextK}',to_jsonb(k+1));
       kind := 'ST6_WITHDRAW_AND_CELL2_REPLENISH'; detail := (o->>'id')||' Model '||model||' -> Station 1 Kanban; Supermarket 2 replenished';
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

revoke all on function kanban_private.ensure_station_access(uuid) from public,anon,authenticated;
revoke all on function kanban_private.station_snapshot(jsonb,text) from public,anon,authenticated;
-- Replacing functions retains the existing explicit RPC grants.
