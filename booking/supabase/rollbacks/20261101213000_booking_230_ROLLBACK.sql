-- booking_230 rollback: poistaa 1.11.2026-kommentit. Funktioiden rungot eivät muuttuneet.
comment on function booking._treatment_plan_status(bigint, timestamp with time zone, timestamp with time zone, integer) is null;
comment on function booking._check_claim(bigint, bigint, bigint, text, text, timestamp with time zone, timestamp with time zone, integer, bigint[], text, text, boolean, boolean, text) is null;
