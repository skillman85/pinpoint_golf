create table if not exists public.course_api_cache (
  cache_key text primary key,
  payload jsonb not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists course_api_cache_expires_at_idx
  on public.course_api_cache (expires_at);

alter table public.course_api_cache enable row level security;

drop policy if exists "service role manages course cache" on public.course_api_cache;
create policy "service role manages course cache"
  on public.course_api_cache
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');
