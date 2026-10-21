-- booking_122 rollback: tuotekuvaukset takaisin plain / 4000.
-- Ei kirjoita published_text-arvoja. Aja vain jos booking_122 on käytössä.

set local lock_timeout = '5s';

update booking.site_texts
   set kind = 'plain', max_len = 4000
 where source_table = 'kb.products'
   and source_column in ('description', 'description_en');

alter table booking.site_texts drop constraint if exists site_texts_kind_check;
alter table booking.site_texts add constraint site_texts_kind_check check (kind in ('plain', 'lite'));
comment on column booking.site_texts.kind is 'plain = pelkkä teksti, lite = **lihavointi** (vain info-kentät).';

create or replace function booking._text_validate(p_class text, p_kind text, p_max integer, p_placeholders text[], p_text text) returns void
language plpgsql immutable set search_path = '' as $$
declare m text[]; v_clean text; v_set text[];
begin
  if p_text is null or btrim(p_text) = '' then perform booking._err('text_empty', 'Teksti ei voi olla tyhjä'); end if;
  if char_length(p_text) > p_max then perform booking._err('too_long', format('Teksti on liian pitkä (%s > %s merkkiä)', char_length(p_text), p_max)); end if;
  if p_text ~ '[\x01-\x08\x0B\x0C\x0E-\x1F]' then perform booking._err('invalid_text', 'Tekstissä on kiellettyjä ohjausmerkkejä'); end if;
  if p_text ~ '<\s*/?\s*[A-Za-z!?]' or p_text ~* 'javascript:' or p_text ~* '\mon[a-z]+\s*=\s*["'']' then perform booking._err('html_not_allowed', 'Raaka HTML tai skripti ei ole sallittu (vain tekstiä)'); end if;
  if p_kind = 'plain' and p_text ~ '\]\(' then perform booking._err('markup_not_allowed', 'Linkkimerkintä ei ole sallittu tässä tekstikentässä'); end if;
  select coalesce(array_agg(distinct x[1] order by x[1]), '{}') into v_set from regexp_matches(p_text, '(\{\{[^{}]*\}\})', 'g') x;
  if exists (select 1 from unnest(v_set) s where s !~ '^\{\{[a-z_]+(:[A-Za-z0-9_]+)?\}\}$') then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  v_clean := regexp_replace(p_text, '\{\{[^{}]*\}\}', '', 'g');
  if v_clean ~ '\{\{|\}\}' then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  if v_set is distinct from (select coalesce(array_agg(distinct s order by s), '{}') from unnest(p_placeholders) s) then
    perform booking._err('placeholder_mismatch', 'Paikkamerkkien pitää vastata tämän tekstin sallittuja paikkamerkkejä');
  end if;
end $$;

create or replace function booking._texts_reg(p_table text, p_pk_col text, p_prefix text, p_field text, p_column text, p_lang_sql text, p_class_sql text, p_where text, p_max integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  execute format($q$insert into booking.site_texts(key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column, published_text, published_version, latest_version, status)
    select %1$L || '.' || s.%2$I::text || '.' || %3$L, %4$s, %5$s, 'plain', %6$s, %7$L, %2$L, s.%2$I::text, %8$L, coalesce(s.%8$I, ''),
           case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end, case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end,
           case when btrim(coalesce(s.%8$I, '')) <> '' then 'published' else 'empty' end
      from %7$s s where %9$s on conflict do nothing$q$, p_prefix, p_pk_col, p_field, p_lang_sql, p_class_sql, p_max, p_table, p_column, p_where);
  get diagnostics n = row_count;
  return n;
end $$;

drop function if exists booking._rich_text_check(text);
