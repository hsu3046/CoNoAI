-- CoNo 사이트 의견 (web/src/app/api/feedback/route.ts 가 service role 로만 쓴다)
create table if not exists public.site_feedback (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  mood smallint check (mood between 1 and 5),
  message text check (message is null or char_length(message) <= 2000),
  email text check (email is null or char_length(email) <= 200),
  ip_hash text not null,
  user_agent text,
  check (mood is not null or message is not null)
);

-- 정책을 두지 않는다: anon·authenticated 는 읽기·쓰기 모두 불가 (PostgREST 로 직접 못 건드린다)
alter table public.site_feedback enable row level security;
revoke all on table public.site_feedback from anon, authenticated;

-- 속도 제한 조회용
create index if not exists site_feedback_ip_created on public.site_feedback (ip_hash, created_at desc);
