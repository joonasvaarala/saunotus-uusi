-- ROLLBACK ops_002_backup_storage_read.
-- Poistaa vain varmuuskopion storage-politiikan. Ei poista käyttäjää, bucketeja eikä tiedostoja.

drop policy if exists backup_storage_reader_select on storage.objects;
