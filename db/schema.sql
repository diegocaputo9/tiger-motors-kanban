-- Isolated from the existing Tiger Motors learning application.
-- Private tables have RLS and no client table grants. Browsers use only the
-- capability-checked RPCs below; a publishable API key alone grants no room access.
create schema kanban_private;
revoke all on schema kanban_private from public;
grant usage on schema kanban_private to anon, authenticated;

create function kanban_private.fresh() returns jsonb
language sql volatile set search_path = '' as $$
  select jsonb_build_object(
    'generation', gen_random_uuid(),
    'orders', (select jsonb_agg(jsonb_build_object(
      'id', 'TM-' || lpad(i::text,3,'0'), 'model', case when i%2=0 then 'T' else 'A' end,
      'spare', i=any(array[2,6,10,14,18,22,26,30]), 'status','planned','option','none') order by i)
      from generate_series(1,30) as i),
    'released',0,'start',null,'attack',false,'attackStart',null,'paused',0,
    'inventory','{"S1":{"A":8,"T":8},"S2":{"A":8,"T":8}}'::jsonb,
    'kanbans','[]'::jsonb,'nextK',1,'spares','[]'::jsonb,'events','[]'::jsonb,'completed',0);
$$;

create table kanban_private.rooms (
  id uuid primary key,
  instructor_key uuid not null,
  station_key uuid not null,
  state jsonb not null default kanban_private.fresh(),
  revision bigint not null default 0,
  receipts uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  check (instructor_key <> station_key)
);
alter table kanban_private.rooms enable row level security;
revoke all on kanban_private.rooms from public, anon, authenticated;

create function kanban_private.add_event(s jsonb, kind text, detail text, ms bigint)
returns jsonb language sql immutable set search_path = '' as $$
 select jsonb_set(s,'{events}',jsonb_build_array(jsonb_build_object(
   'time',to_char(to_timestamp(ms/1000.0) at time zone 'UTC','HH24:MI:SS') || ' UTC',
   'type',kind,'details',detail)) || (s->'events'));
$$;

create function kanban_private.advance(s jsonb, ms bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare target integer; b integer; i integer; o jsonb;
begin
 if s->>'start' is null or (s->>'attack')::boolean then return s; end if;
 target := least(5, greatest(0, (ms-(s->>'start')::bigint-(s->>'paused')::bigint)/480000)::integer+1);
 while (s->>'released')::integer < target loop
   b := (s->>'released')::integer;
   for i in b*6..b*6+5 loop
     o := s->'orders'->i;
     s := jsonb_set(s,array['orders',i::text,'status'],'"released"');
     if (o->>'spare')::boolean then
       s := jsonb_set(s,array['orders',i::text,'option'],'"queued"');
       s := jsonb_set(s,'{spares}',(s->'spares') || jsonb_build_array(jsonb_build_object('id',o->>'id','status','open')));
     end if;
   end loop;
   s := jsonb_set(s,'{released}',to_jsonb(b+1));
   s := kanban_private.add_event(s,'BATCH_RELEASE','Batch '||(b+1),ms);
 end loop;
 return s;
end;
$$;

-- SECURITY DEFINER is limited to this non-exposed schema. These endpoints use
-- unguessable room capabilities, rather than changing this project's Auth users
-- or settings. Every read and write validates its capability before accessing state.
create function kanban_private.create_room(p_room uuid, p_instructor uuid, p_station uuid)
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
 return jsonb_build_object('room',p_room);
end;
$$;

create function kanban_private.room_action(
 p_room uuid, p_key uuid, p_action text default 'sync', p_request uuid default null,
 p_generation uuid default null, p_item text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r kanban_private.rooms%rowtype; s jsonb; ms bigint;
 is_instructor boolean; i integer; idx integer; o jsonb; model text;
 stock integer; k integer; cell integer; kind text; detail text;
begin
 select * into r from kanban_private.rooms where id=p_room for update;
 if not found or p_key is null or (p_key<>r.instructor_key and p_key<>r.station_key) then
   raise exception 'Room link is invalid';
 end if;
 is_instructor := p_key=r.instructor_key;
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
   perform realtime.send(jsonb_build_object('revision',r.revision),'changed','kanban:'||r.station_key,false);
 elsif r.receipts is distinct from (select receipts from kanban_private.rooms where id=p_room) then
   update kanban_private.rooms set receipts=r.receipts where id=p_room;
 end if;
 return jsonb_build_object('state',s,'revision',r.revision,'serverTime',ms,
   'role',case when is_instructor then 'instructor' else 'station' end,'stationKey',r.station_key);
end;
$$;

-- Only invoker wrappers are exposed through PostgREST. The private functions
-- have a fixed empty search_path and perform their own capability authorization.
create function public.kanban_create_room(p_room uuid,p_instructor uuid,p_station uuid)
returns jsonb language sql security invoker set search_path = '' as $$
 select kanban_private.create_room(p_room,p_instructor,p_station);
$$;
create function public.kanban_room_action(
 p_room uuid,p_key uuid,p_action text default 'sync',p_request uuid default null,
 p_generation uuid default null,p_item text default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select kanban_private.room_action(p_room,p_key,p_action,p_request,p_generation,p_item);
$$;

revoke all on all functions in schema kanban_private from public,anon,authenticated;
grant execute on function kanban_private.create_room(uuid,uuid,uuid) to anon,authenticated;
grant execute on function kanban_private.room_action(uuid,uuid,text,uuid,uuid,text) to anon,authenticated;
revoke all on function public.kanban_create_room(uuid,uuid,uuid) from public;
revoke all on function public.kanban_room_action(uuid,uuid,text,uuid,uuid,text) from public;
grant execute on function public.kanban_create_room(uuid,uuid,uuid) to anon,authenticated;
grant execute on function public.kanban_room_action(uuid,uuid,text,uuid,uuid,text) to anon,authenticated;
