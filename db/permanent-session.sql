-- One reusable production line. Existing room records and access keys are retained.
create table kanban_private.installation (
  singleton boolean primary key default true check(singleton),
  room_id uuid not null unique references kanban_private.rooms(id)
);
alter table kanban_private.installation enable row level security;
revoke all on kanban_private.installation from public,anon,authenticated;

-- Reuse the most recently established session without resetting its production.
insert into kanban_private.installation(singleton,room_id)
select true,id from kanban_private.rooms order by created_at desc limit 1;

-- Also supports a fresh installation, without exposing session creation to browsers.
do $$
declare session_id uuid;
begin
 if not exists(select 1 from kanban_private.installation) then
   insert into kanban_private.rooms(id,instructor_key,station_key)
   values(gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) returning id into session_id;
   perform kanban_private.ensure_station_access(session_id);
   insert into kanban_private.installation(singleton,room_id) values(true,session_id);
 end if;
end $$;

-- Exposes only the session identifier, never instructor or station access keys.
create function kanban_private.active_session() returns uuid
language sql stable security definer set search_path = '' as $$
 select room_id from kanban_private.installation where singleton=true;
$$;
revoke all on function kanban_private.active_session() from public;
grant execute on function kanban_private.active_session() to anon,authenticated;

create function public.kanban_session_info() returns jsonb
language sql stable security invoker set search_path = '' as $$
 select jsonb_build_object('sessionId',kanban_private.active_session());
$$;
revoke all on function public.kanban_session_info() from public;
grant execute on function public.kanban_session_info() to anon,authenticated;

create or replace function public.kanban_room_action(
 p_room uuid,p_key uuid,p_action text default 'sync',p_request uuid default null,
 p_generation uuid default null,p_item text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
 if p_room is distinct from kanban_private.active_session() then
   raise exception 'Open the permanent instructor or station link for this production line';
 end if;
 return kanban_private.room_action(p_room,p_key,p_action,p_request,p_generation,p_item);
end;
$$;

-- Browsers can reuse/reset the selected line but can no longer create new rooms.
revoke all on function public.kanban_create_room(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function kanban_private.create_room(uuid,uuid,uuid) from public,anon,authenticated;
