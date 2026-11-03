-- 2C4: asignación automática de cobros a cuotas del cronograma vigente.
-- No crea ingresos: solo distribuye el monto de un evento YA registrado.
-- En ventas sin cronograma se conserva el comportamiento de crédito legacy.
-- Excluye cronogramas versionados >1 hasta contar con transferencia auditable.

CREATE UNIQUE INDEX IF NOT EXISTS venta_cuota_mov_2c4_unique_cobro_idx
  ON public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id)
  WHERE tipo='cobro';

CREATE FUNCTION private.financial_2c4_allocate_cash_receipt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $allocate$
DECLARE
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_intent private.financial_2c2_write_intents%ROWTYPE;
 v_count integer;
 v_bad_count integer;
 v_min_number integer;
 v_max_number integer;
 v_due numeric;
 v_applied numeric;
 v_remaining numeric;
 v_room numeric;
 v_piece numeric;
 v_total_assigned numeric := 0;
 v_previous numeric;
 v_quota record;
BEGIN
 IF NEW.tipo<>'cobro' THEN
   RETURN NEW;
 END IF;

 -- Una venta sin historial de cuotas NO recibe vencimientos ficticios.
 SELECT cr.* INTO v_schedule
 FROM public.venta_cronogramas cr
 WHERE cr.organization_id=NEW.organization_id
   AND cr.venta_id=NEW.venta_id
   AND cr.estado='vigente'
 FOR UPDATE;
 IF NOT FOUND THEN
   IF EXISTS (
     SELECT 1 FROM public.venta_cronogramas cr
     WHERE cr.organization_id=NEW.organization_id
       AND cr.venta_id=NEW.venta_id
   ) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Hay cronogramas anteriores pero ninguno vigente';
   END IF;
   RETURN NEW;
 END IF;

 -- La versión 2 requiere reasignaciones históricas explícitas no incluidas
 -- aún en 2C4: no recontar movimientos de versiones sustituidas.
 IF v_schedule.version<>1 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma versionado requiere transferencia de asignaciones';
 END IF;

 -- Un cobro con cuotas solo puede proceder de uno de los dos escritores
 -- internos, ya que ellos crean esta intención privada antes del evento.
 SELECT i.* INTO v_intent
 FROM private.financial_2c2_write_intents i
 WHERE i.organization_id=NEW.organization_id
   AND i.venta_id=NEW.venta_id
   AND i.tx_id=pg_catalog.pg_current_xact_id()
   AND i.operacion_id=NEW.operacion_id
   AND i.pago_id IS NULL
   AND i.etapa='insert_payment';
 IF NOT FOUND OR v_intent.monto IS DISTINCT FROM NEW.delta_cobros
    OR NEW.delta_exigible<>0 OR NEW.pago_id IS NULL
    OR NEW.delta_cobros<=0 OR NEW.delta_cobros<>round(NEW.delta_cobros,2) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Evento de cuota sin intención de cobro válida';
 END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=NEW.organization_id
   AND cf.venta_id=NEW.venta_id
 FOR UPDATE;
 IF NOT FOUND OR v_account.moneda<>'PEN'
   OR v_account.estado_conciliacion<>'conciliada'
   OR NEW.delta_cobros>v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera no elegible para asignar cobro a cuotas';
 END IF;

 -- Suma de obligaciones pendientes = saldo canónico previo al cobro.
 -- Solo se admiten movimientos positivos de cobro hasta disponer de
 -- reversos y NC (fase posterior).
 SELECT COUNT(*),MIN(c.numero),MAX(c.numero),
        COALESCE(SUM(c.importe_vigente),0),
        COUNT(*) FILTER (
          WHERE c.es_legado OR c.vencimiento IS NULL
             OR c.importe_vigente<=0
             OR c.importe_vigente<>round(c.importe_vigente,2)
        )
 INTO v_count,v_min_number,v_max_number,v_due,v_bad_count
 FROM public.venta_cuotas c
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id
   AND c.cronograma_id=v_schedule.id;

 IF v_count=0 OR v_min_number<>1 OR v_max_number<>v_count
   OR v_bad_count>0 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma incompleto, legado o importes inválidos';
 END IF;

 SELECT COALESCE(SUM(m.importe_asignado),0) INTO v_applied
 FROM public.venta_cuota_movimientos m
 JOIN public.venta_cuotas c
   ON c.organization_id=m.organization_id
   AND c.venta_id=m.venta_id AND c.id=m.cuota_id
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id;

 IF v_applied<0 OR v_applied<>round(v_applied,2)
    OR v_due-v_applied IS DISTINCT FROM v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Saldo de cuotas no coincide con deuda canónica anterior al cobro';
 END IF;

 v_remaining:=NEW.delta_cobros;
 FOR v_quota IN
  SELECT c.id,c.numero,c.vencimiento,c.importe_vigente,
         COALESCE((
           SELECT SUM(m.importe_asignado)
           FROM public.venta_cuota_movimientos m
           WHERE m.organization_id=c.organization_id
             AND m.venta_id=c.venta_id AND m.cuota_id=c.id
         ),0) as asignado
  FROM public.venta_cuotas c
  WHERE c.organization_id=NEW.organization_id
    AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id
  ORDER BY c.vencimiento,c.numero
 LOOP
   IF v_remaining=0 THEN EXIT; END IF;
   v_room:=v_quota.importe_vigente-v_quota.asignado;
   IF v_room<0 OR v_room<>round(v_room,2) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Cuota excede su obligación vigente';
   END IF;
   v_piece:=LEAST(v_remaining,v_room);
   IF v_piece>0 THEN
     INSERT INTO public.venta_cuota_movimientos(
       organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado
     ) VALUES(
       NEW.organization_id,NEW.venta_id,v_quota.id,NEW.id,'cobro',v_piece
     );
     v_remaining:=v_remaining-v_piece;
     v_total_assigned:=v_total_assigned+v_piece;
   END IF;
 END LOOP;

 IF v_remaining<>0 OR v_total_assigned<>NEW.delta_cobros THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Asignación incompleta de cobro, rollback de transacción';
 END IF;
 RETURN NEW;
END;
$allocate$;

REVOKE ALL ON FUNCTION private.financial_2c4_allocate_cash_receipt()
  FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER zz_fin2c4_allocate_receipt_to_installments
 AFTER INSERT ON public.venta_eventos_financieros
 FOR EACH ROW
 EXECUTE FUNCTION private.financial_2c4_allocate_cash_receipt();

-- Lectura informativa sin escribir ni inventar vencimientos históricos.
CREATE FUNCTION private.financial_2c4_installments(
 p_organization_id uuid,
 p_venta_id bigint,
 p_local_date date DEFAULT NULL
)
RETURNS TABLE(
 cuota_id uuid,
 numero integer,
 vencimiento date,
 importe_vigente numeric,
 importe_cobrado numeric,
 saldo_pendiente numeric,
 estado text,
 vencida boolean,
 cronograma_version integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path=''
AS $read$
 WITH active_schedule AS (
   SELECT cr.id,cr.version
   FROM public.venta_cronogramas cr
   WHERE cr.organization_id=p_organization_id
     AND cr.venta_id=p_venta_id AND cr.estado='vigente'
 ), installments AS (
   SELECT c.id,c.numero,c.vencimiento,c.importe_vigente,
          cr.version,
          COALESCE((
            SELECT SUM(m.importe_asignado)
            FROM public.venta_cuota_movimientos m
            WHERE m.organization_id=c.organization_id
              AND m.venta_id=c.venta_id AND m.cuota_id=c.id
          ),0) AS paid
   FROM public.venta_cuotas c
   JOIN active_schedule cr ON cr.id=c.cronograma_id
   WHERE c.organization_id=p_organization_id
     AND c.venta_id=p_venta_id
 )
 SELECT id,numero,vencimiento,importe_vigente,paid,
        importe_vigente-paid,
        CASE WHEN importe_vigente-paid=0 THEN 'pagada'
             WHEN paid>0 THEN 'parcial'
             ELSE 'pendiente' END,
        (importe_vigente-paid>0 AND vencimiento IS NOT NULL
         AND vencimiento<COALESCE(
             p_local_date,(now() AT TIME ZONE 'America/Lima')::date)),
        version
 FROM installments
 ORDER BY vencimiento NULLS LAST,numero;
$read$;

REVOKE ALL ON FUNCTION private.financial_2c4_installments(uuid,bigint,date)
 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION private.financial_2c4_installments(uuid,bigint,date)
 IS '2C4: lectura interna de cuotas y vencidas por dia local America/Lima, sin contabilidad de ingresos.';
