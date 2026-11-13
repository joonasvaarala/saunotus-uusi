-- booking_262 is verification-only: no installation SQL to undo. Capture belongs to259.
-- Fail closed rather than falsely marking capture rolled back or disabling history capture.
-- Roll back newsletter UI/dispatch with259 feature rollback; keep262 and its metadata applied.
-- This guard never modifies tables, triggers, functions, permissions or suppression history.
do $$begin
 raise exception 'booking_262 is verification-only: no destructive reverse SQL; retain permanent259 capture and use reviewed259 feature rollback only';
end$$;
