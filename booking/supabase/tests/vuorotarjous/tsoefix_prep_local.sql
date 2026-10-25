-- tsoefix_prep_local.sql: VAIN paikalliseen testikantaan (EI tuotantoon). Tuo paikallisen kannan tuotannon tilaan niiltä osin kuin
-- soefix-migraatio ja -testi tarvitsevat (tuotanto luettu SELECTillä 25.10.2026): tervetulotekstin fi/en-rivit ja versiot 1,
-- shift_offer.email_enabled = true, shift_offer.offer_uncertain_shifts = true. Paikallisesti on lisäksi ajettava ennen tätä:
-- botgw-skeema (20261025145539_botgw_otto_disabled, tuotannossa jo ajettu; history-tiedosto erillisessä bot-gateway-PR:ssä), tuotannon parse_shift_title-määrittely ja fixtures/10_test_helpers.sql.
insert into booking.site_texts (id, key, lang, class, kind, max_len, placeholders, published_text, published_version, latest_version, status, needs_translation, published_at, created_at, updated_at, needs_review)
overriding system value values
 (23744, 'shift_offer.whatsapp.welcome', 'fi', 'normal', 'plain', 280, '{"{{var:link}}","{{var:name}}"}', E'Hei {{var:name}}. Tässä Tapio, Saunotuksen työvuorojen apuri. Kun sinulle on vapaa vuoro, saat viestin, johon vastaat painikkeella tai linkillä. Omat avoimet ja vastatut vuorosi näet täältä: {{var:link}}\n\n–Tapio', 1, 1, 'published', false, '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00', false),
 (23745, 'shift_offer.whatsapp.welcome', 'en', 'normal', 'plain', 310, '{"{{var:link}}","{{var:name}}"}', E'Hi {{var:name}}. This is Tapio, the shift assistant of Saunotus. When a shift is available for you, you will get a message that you can answer with a button or a link. You can see your open and answered shifts here: {{var:link}}\n\n–Tapio', 1, 1, 'published', false, '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00', false)
on conflict (key, lang) do nothing;
insert into booking.site_text_versions (id, text_id, version, text, status, base_version, author_kind, author_label, reason, escalation, protected, published_at, created_at)
overriding system value values
 (10037, 23744, 1, E'Hei {{var:name}}. Tässä Tapio, Saunotuksen työvuorojen apuri. Kun sinulle on vapaa vuoro, saat viestin, johon vastaat painikkeella tai linkillä. Omat avoimet ja vastatut vuorosi näet täältä: {{var:link}}\n\n–Tapio', 'published', 0, 'human', 'tuotanto', 'booking_153: tervetuloviesti työntekijän ensimmäiseen WhatsApp-viestiin (24 h vapaamuotoinen ikkuna, asetus shift_offer.welcome_enabled oletus pois). Moottori lukee vain fi-rivin.', '{}', false, '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00'),
 (10038, 23745, 1, E'Hi {{var:name}}. This is Tapio, the shift assistant of Saunotus. When a shift is available for you, you will get a message that you can answer with a button or a link. You can see your open and answered shifts here: {{var:link}}\n\n–Tapio', 'published', 0, 'human', 'tuotanto', 'booking_153: tervetuloviesti työntekijän ensimmäiseen WhatsApp-viestiin (24 h vapaamuotoinen ikkuna, asetus shift_offer.welcome_enabled oletus pois). Moottori lukee vain fi-rivin.', '{}', false, '2026-10-24T14:14:11.629013+00:00', '2026-10-24T14:14:11.629013+00:00')
on conflict do nothing;
update booking.settings set value = 'true'::jsonb where key in ('shift_offer.email_enabled', 'shift_offer.offer_uncertain_shifts');
-- tuotannon oikeudet parse_shift_title(text):lle (tuotanto: postgres=X/postgres,service_role=X/postgres)
revoke all on function public.parse_shift_title(text) from public, anon, authenticated;
grant execute on function public.parse_shift_title(text) to service_role;
