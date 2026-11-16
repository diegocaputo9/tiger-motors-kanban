-- A read-only PostgREST database request for the external availability check.
-- No room credentials, table access, production updates, or stored heartbeat rows.
create function public.kanban_keepalive() returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select jsonb_build_object('ok',true,'checked_at',clock_timestamp());
$$;
revoke all on function public.kanban_keepalive() from public;
grant execute on function public.kanban_keepalive() to anon,authenticated;
