-- Evita diferencias de huella de idempotencia al cambiar TimeZone de la sesión.
-- jsonb_build_object(timestamptz) debe usar representación estable UTC.
ALTER FUNCTION private.financial_2c2_record_transfer_payment(
 uuid,bigint,uuid,text,numeric,timestamptz
) SET TimeZone TO 'UTC';
