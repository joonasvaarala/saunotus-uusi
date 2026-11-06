-- booking_262 permanent opt-out infrastructure is intentionally NON-REVERSIBLE.
-- Fail closed rather than falsely marking capture rolled back or disabling history capture.
-- Roll back newsletter UI/dispatch with259 feature rollback; keep262 and its metadata applied.
-- This guard never modifies tables, triggers, functions, permissions or suppression history.
do $$begin
 raise exception 'booking_262 capture is permanent: retain it; use reviewed booking_259 feature rollback only';
end$$;
