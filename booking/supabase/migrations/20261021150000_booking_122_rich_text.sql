-- booking_122: tuotekuvaukset saavat rich-tekstin (p, br, strong/b, em/i, h2/h3, ul/ol/li, a).
-- Ei kirjoita published_text-arvoja uudelleen. Hinnat, ALV ja osoitteet ennallaan.
-- Uudet kb.products-kuvaukset rekisteröidään kind=rich, max 8000. Muut kentät pysyvät plain.
-- Rollback: rollbacks/20261021150000_booking_122_ROLLBACK.sql

set local lock_timeout = '5s';

alter table booking.site_texts drop constraint if exists site_texts_kind_check;
alter table booking.site_texts add constraint site_texts_kind_check check (kind in ('plain', 'lite', 'rich'));
comment on column booking.site_texts.kind is 'plain = pelkkä teksti, lite = **lihavointi**, rich = kapea HTML-allowlist (tuotekuvaus).';

create or replace function booking._rich_text_check(p_text text) returns void
language plpgsql immutable set search_path = '' as $$
declare v_name text; v_href text;
begin
  if p_text ~* '<\s*/?\s*(script|style|iframe|object|embed|img|svg|math|link|meta|form|input|button|video|audio|canvas|frame|frameset|applet|base|noscript|template)\b' then
    perform booking._err('html_not_allowed', 'Kielletty elementti');
  end if;
  if p_text ~* '\mon[a-z]+\s*=' or p_text ~* 'javascript\s*:' or p_text ~* 'vbscript\s*:' or p_text ~* 'data\s*:' then
    perform booking._err('html_not_allowed', 'Skripti tai kielletty osoite');
  end if;
  if p_text ~* '(^|[^a-z])style\s*=' then
    perform booking._err('html_not_allowed', 'Tyylit eivät ole sallittuja');
  end if;
  for v_name in select lower(m[1]) from regexp_matches(p_text, '<\s*/?\s*([a-zA-Z][a-zA-Z0-9]*)', 'g') as m
  loop
    if v_name not in ('p', 'br', 'strong', 'b', 'em', 'i', 'h2', 'h3', 'ul', 'ol', 'li', 'a') then
      perform booking._err('html_not_allowed', 'Sallitut tagit: p, br, strong, b, em, i, h2, h3, ul, ol, li, a');
    end if;
  end loop;
  for v_href in select m[1] from regexp_matches(p_text, 'href\s*=\s*"([^"]*)"', 'gi') as m
  loop
    if v_href ~* '&#|&[a-z]+;' or lower(regexp_replace(v_href, '[[:space:]]', '', 'g')) !~ '^(https?://[^[:space:]<>"]+|mailto:[^@[:space:]<>"]+@[^@[:space:]<>"]+\.[^@[:space:]<>"]+|\{tilaus_linkki\}|\{linkki\})$' then
      perform booking._err('html_not_allowed', 'Linkin osoite ei ole sallittu');
    end if;
  end loop;
end $$;

revoke all on function booking._rich_text_check(text) from public, anon, authenticated;
grant execute on function booking._rich_text_check(text) to service_role;

create or replace function booking._text_validate(p_class text, p_kind text, p_max integer, p_placeholders text[], p_text text) returns void
language plpgsql immutable set search_path = '' as $$
declare m text[]; v_clean text; v_set text[];
begin
  if p_text is null or btrim(p_text) = '' then perform booking._err('text_empty', 'Teksti ei voi olla tyhjä'); end if;
  if char_length(p_text) > p_max then perform booking._err('too_long', format('Teksti on liian pitkä (%s > %s merkkiä)', char_length(p_text), p_max)); end if;
  if p_text ~ '[\x01-\x08\x0B\x0C\x0E-\x1F]' then perform booking._err('invalid_text', 'Tekstissä on kiellettyjä ohjausmerkkejä'); end if;
  if p_kind = 'rich' then
    perform booking._rich_text_check(p_text);
  elsif p_text ~ '<\s*/?\s*[A-Za-z!?]' or p_text ~* 'javascript:' or p_text ~* '\mon[a-z]+\s*=\s*["'']' then
    perform booking._err('html_not_allowed', 'Raaka HTML tai skripti ei ole sallittu (vain tekstiä)');
  end if;
  if p_kind = 'plain' and p_text ~ '\]\(' then perform booking._err('markup_not_allowed', 'Linkkimerkintä ei ole sallittu tässä tekstikentässä'); end if;
  select coalesce(array_agg(distinct x[1] order by x[1]), '{}') into v_set from regexp_matches(p_text, '(\{\{[^{}]*\}\})', 'g') x;
  if exists (select 1 from unnest(v_set) s where s !~ '^\{\{[a-z_]+(:[A-Za-z0-9_]+)?\}\}$') then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  v_clean := regexp_replace(p_text, '\{\{[^{}]*\}\}', '', 'g');
  if v_clean ~ '\{\{|\}\}' then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  if v_set is distinct from (select coalesce(array_agg(distinct s order by s), '{}') from unnest(p_placeholders) s) then
    perform booking._err('placeholder_mismatch', 'Paikkamerkkien pitää vastata tämän tekstin sallittuja paikkamerkkejä');
  end if;
end $$;

-- uusi tuotekuvaus: kind rich / 8000. Olemassa oleva _texts_reg-kutsu ei muutu; vain kuvauskenttä.
create or replace function booking._texts_reg(p_table text, p_pk_col text, p_prefix text, p_field text, p_column text, p_lang_sql text, p_class_sql text, p_where text, p_max integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer; v_kind text := 'plain'; v_max integer;
begin
  if p_table = 'kb.products' and p_field = 'description' then v_kind := 'rich'; v_max := 8000; else v_max := p_max; end if;
  execute format($q$insert into booking.site_texts(key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column, published_text, published_version, latest_version, status)
    select %1$L || '.' || s.%2$I::text || '.' || %3$L, %4$s, %5$s, %10$L, %6$s, %7$L, %2$L, s.%2$I::text, %8$L, coalesce(s.%8$I, ''),
           case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end, case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end,
           case when btrim(coalesce(s.%8$I, '')) <> '' then 'published' else 'empty' end
      from %7$s s where %9$s on conflict do nothing$q$, p_prefix, p_pk_col, p_field, p_lang_sql, p_class_sql, v_max, p_table, p_column, p_where, v_kind);
  get diagnostics n = row_count;
  return n;
end $$;

-- metadata vain. Julkaistua kuvaus- tai hintatekstiä ei kosketa.
update booking.site_texts
   set kind = 'rich', max_len = 8000
 where source_table = 'kb.products'
   and source_column in ('description', 'description_en');
