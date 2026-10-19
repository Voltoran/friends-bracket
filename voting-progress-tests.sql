-- Integration tests; all fixtures roll back, including temporary admin access.
begin;
do $$
declare token text:=encode(extensions.gen_random_bytes(32),'hex'); c uuid; other_c uuid; codes text[]; ids uuid[];
  m uuid; first_m uuid; r int; i int; report jsonb; item jsonb; before_data jsonb; after_data jsonb;
begin
  insert into bracket_private.admin_sessions(token_hash,expires_at) values(bracket_private.secret_hash(token),now()+interval '1 hour');
  perform set_config('bracket.admin_token',token,true);
  for i in 1..3 loop
    codes[i]:=public.bracket_issue_code('Progress test '||i);
    select id into m from bracket_private.voters where code_hash=bracket_private.code_hash(codes[i]);
    ids[i]:=m;
  end loop;
  c:=public.bracket_create_category('Progress test eleven',array(select 'Option '||n from generate_series(1,11) n));
  report:=public.bracket_admin(token,'voting_progress',jsonb_build_object('p_category',c))->'data';
  if report->>'total'<>'3' or report->'category'->>'status'<>'draft' then raise exception 'TEST: draft or byes'; end if;
  perform set_config('bracket.admin_token',token,true);
  if exists(select 1 from jsonb_array_elements(report->'voters') x where x->>'voted'<>'0') then raise exception 'TEST: other category counted'; end if;
  perform public.bracket_start(c);
  select id into first_m from bracket_private.matches where category_id=c and round=1 and position=5;
  perform public.bracket_vote(codes[1],first_m,1);
  perform public.bracket_vote(codes[2],first_m,2);
  select id into m from bracket_private.matches where category_id=c and round=1 and position=6;
  perform public.bracket_vote(codes[1],m,1);
  other_c:=public.bracket_create_category('Other progress test',array['A','B','C','D']);
  perform public.bracket_start(other_c);
  select id into m from bracket_private.matches where category_id=other_c and round=1 and position=0;
  perform public.bracket_vote(codes[1],m,1);
  perform public.bracket_toggle_voter(ids[1],false);
  select jsonb_build_object('categories',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.categories x),
    'matches',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.matches x),
    'votes',(select jsonb_agg(to_jsonb(x) order by voter_id,match_id,ballot) from bracket_private.votes x),
    'voters',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.voters x)) into before_data;
  report:=bracket_private.voting_progress(c);
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[1]::text;
  if item->>'voted'<>'2' or item->>'active'<>'false' then raise exception 'TEST: partial or disabled voter'; end if;
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[2]::text;
  if item->>'voted'<>'1' then raise exception 'TEST: second voter'; end if;
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[3]::text;
  if item->>'voted'<>'0' then raise exception 'TEST: nonvoter'; end if;
  if exists(select 1 from jsonb_array_elements(report->'voters') x, jsonb_object_keys(x) k where k not in ('id','label','active','voted')) then raise exception 'TEST: unexpected personal report fields'; end if;
  if public.bracket_state(null) ? 'voters' or public.bracket_state(null) ? 'voting_progress' then raise exception 'TEST: public report'; end if;
  select jsonb_build_object('categories',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.categories x),
    'matches',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.matches x),
    'votes',(select jsonb_agg(to_jsonb(x) order by voter_id,match_id,ballot) from bracket_private.votes x),
    'voters',(select jsonb_agg(to_jsonb(x) order by id) from bracket_private.voters x)) into after_data;
  if before_data is distinct from after_data then raise exception 'TEST: reporting changed data'; end if;
  if public.bracket_runoff(c)<>1 then raise exception 'TEST: runoff setup'; end if;
  report:=bracket_private.voting_progress(c);
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[1]::text;
  if item->>'voted'<>'1' then raise exception 'TEST: archived vote counted'; end if;
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[2]::text;
  if item->>'voted'<>'0' then raise exception 'TEST: old ballot counted'; end if;
  if (select count(*) from bracket_private.votes where match_id=first_m)<>2 then raise exception 'TEST: vote history lost'; end if;
  perform public.bracket_toggle_voter(ids[1],true);
  perform public.bracket_vote(codes[1],first_m,1);
  select id into m from bracket_private.matches where category_id=c and round=1 and position=7;
  perform public.bracket_vote(codes[1],m,1);
  report:=bracket_private.voting_progress(c);
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[1]::text;
  if item->>'voted'<>'3' then raise exception 'TEST: complete voter'; end if;
  perform public.bracket_close_round(c);
  report:=bracket_private.voting_progress(c);
  if report->>'total'<>'4' or report->'category'->>'round'<>'2' or exists(select 1 from jsonb_array_elements(report->'voters') x where x->>'voted'<>'0') then raise exception 'TEST: next round'; end if;
  for r in 2..4 loop
    for m in select id from bracket_private.matches where category_id=c and round=r loop perform public.bracket_vote(codes[1],m,1); end loop;
    perform public.bracket_close_round(c);
  end loop;
  report:=bracket_private.voting_progress(c);
  if report->>'total'<>'1' or report->'category'->>'status'<>'finished' then raise exception 'TEST: final'; end if;
  select x into item from jsonb_array_elements(report->'voters') x where x->>'id'=ids[1]::text;
  if item->>'voted'<>'1' then raise exception 'TEST: final vote missing'; end if;
  perform public.bracket_delete_category(c);
  begin perform bracket_private.voting_progress(c); raise exception 'TEST: deleted report'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
  begin perform bracket_private.voting_progress(gen_random_uuid()); raise exception 'TEST: missing report'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
  perform set_config('bracket.admin_token','',true);
  begin perform bracket_private.voting_progress(other_c); raise exception 'TEST: guest report'; exception when insufficient_privilege then null; end;
  if public.bracket_admin(null,'voting_progress',jsonb_build_object('p_category',other_c))->>'code'<>'admin_session_expired' then raise exception 'TEST: guest gateway'; end if;
  if has_function_privilege('anon','bracket_private.voting_progress(uuid)','execute') or has_function_privilege('authenticated','bracket_private.voting_progress(uuid)','execute') then raise exception 'TEST: direct report grant'; end if;
end $$;
rollback;
select 'PASS: private read-only participation; 11 entries, partial/complete/nonvoters, disabled codes, current ballots, next round, final, data preservation and guest denial. Fixtures rolled back.' as result;
