-- F9.2 SaaS: termina la transición de idempotencia de inventario a namespace tenant-local.
-- Un UUID generado por ORG_A no debe reservar ese UUID para ORG_B.
BEGIN;

-- La pertenencia activa sigue siendo obligatoria, pero nunca se consulta otro tenant
-- para decidir si un request_id está disponible. La autoridad es (tenant, request_id).
CREATE OR REPLACE FUNCTION private.assert_inventory_request_scope(p_request_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_current_organization_id();
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id is required';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.assert_inventory_request_scope(uuid)
  FROM PUBLIC, anon, authenticated;

-- Convierte cualquier autoridad UNIQUE/PK request_id-only de las tablas
-- idempotentes directas a claves tenant-local. Incluye constraints y también
-- índices UNIQUE standalone. El bloque falla cerrado ante estados ambiguos.
DO $tenant_request_constraints$
DECLARE
  v_table_name text;
  v_table regclass;
  v_request_attnum smallint;
  v_org_attnum smallint;
  v_old record;
  v_old_count integer;
  v_old_was_primary boolean;
  v_has_composite boolean;
  v_new_name text;
BEGIN
  FOREACH v_table_name IN ARRAY ARRAY[
    'inventario_operaciones_idempotentes',
    'sys_processed_requests',
    'transferencias_stock'
  ]::text[]
  LOOP
    v_table := to_regclass(format('public.%I', v_table_name));
    IF v_table IS NULL THEN
      RAISE EXCEPTION 'F9.2 expected inventory table % is missing', v_table_name;
    END IF;

    SELECT attnum INTO v_request_attnum
    FROM pg_attribute
    WHERE attrelid=v_table AND attname='request_id' AND NOT attisdropped;
    SELECT attnum INTO v_org_attnum
    FROM pg_attribute
    WHERE attrelid=v_table AND attname='organization_id' AND NOT attisdropped;

    IF v_request_attnum IS NULL OR v_org_attnum IS NULL THEN
      RAISE EXCEPTION 'F9.2 table % lacks request_id/organization_id', v_table_name;
    END IF;

    SELECT count(*) INTO v_old_count
    FROM pg_constraint
    WHERE conrelid=v_table
      AND contype IN ('p','u')
      AND conkey = ARRAY[v_request_attnum]::smallint[];

    IF v_old_count > 1 THEN
      RAISE EXCEPTION 'F9.2 found multiple global request constraints on %', v_table_name;
    END IF;

    v_old_was_primary := false;
    FOR v_old IN
      SELECT conname,contype
      FROM pg_constraint
      WHERE conrelid=v_table
        AND contype IN ('p','u')
        AND conkey = ARRAY[v_request_attnum]::smallint[]
    LOOP
      v_old_was_primary := v_old.contype='p';
      EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', v_table, v_old.conname);
    END LOOP;

    -- Un índice UNIQUE standalone también reservaría request_id globalmente aunque
    -- no exista una constraint visible. Los índices que respaldan constraints se
    -- excluyen porque ya fueron gestionados por ALTER TABLE ... DROP CONSTRAINT.
    FOR v_old IN
      SELECT idx.relname AS index_name
      FROM pg_index i
      JOIN pg_class idx ON idx.oid=i.indexrelid
      WHERE i.indrelid=v_table
        AND i.indisunique
        AND i.indisvalid
        AND i.indisready
        AND i.indnkeyatts=1
        AND pg_get_indexdef(i.indexrelid,1,true)='request_id'
        AND NOT EXISTS (
          SELECT 1
          FROM pg_constraint pc
          WHERE pc.conindid=i.indexrelid
        )
    LOOP
      EXECUTE format('DROP INDEX %I.%I','public',v_old.index_name);
    END LOOP;

    SELECT EXISTS(
      SELECT 1
      FROM pg_constraint
      WHERE conrelid=v_table
        AND contype IN ('p','u')
        AND conkey = ARRAY[v_org_attnum,v_request_attnum]::smallint[]
    ) INTO v_has_composite;

    IF NOT v_has_composite THEN
      IF v_old_was_primary THEN
        v_new_name := left(v_table_name || '_organization_request_pkey', 63);
        EXECUTE format(
          'ALTER TABLE %s ADD CONSTRAINT %I PRIMARY KEY (organization_id,request_id)',
          v_table,v_new_name
        );
      ELSE
        v_new_name := left(v_table_name || '_organization_request_key', 63);
        EXECUTE format(
          'ALTER TABLE %s ADD CONSTRAINT %I UNIQUE (organization_id,request_id)',
          v_table,v_new_name
        );
      END IF;
    END IF;
  END LOOP;
END;
$tenant_request_constraints$;

-- Índices tenant-leading para retries, diagnóstico y probes de concurrencia.
CREATE INDEX IF NOT EXISTS inventario_operaciones_idempotentes_org_request_idx
  ON public.inventario_operaciones_idempotentes(organization_id,request_id);
CREATE INDEX IF NOT EXISTS sys_processed_requests_org_request_idx
  ON public.sys_processed_requests(organization_id,request_id);
CREATE INDEX IF NOT EXISTS transferencias_stock_org_request_idx
  ON public.transferencias_stock(organization_id,request_id);
CREATE INDEX IF NOT EXISTS inventory_traceability_receipts_org_request_idx
  ON public.inventory_traceability_receipts(organization_id,request_id);
CREATE INDEX IF NOT EXISTS inventory_traceability_consumptions_org_request_idx
  ON public.inventory_traceability_consumptions(organization_id,request_id,product_id,warehouse_id);

-- La implementación histórica de recepción trazable usa request_id como PK global
-- y hace su lookup interno sólo por UUID. Para no reescribir una rutina madura ni
-- romper retries ya persistidos, el wrapper traduce únicamente los requests nuevos
-- a una clave interna determinista namespaced por organization_id. Los requests
-- legacy del tenant actual conservan su UUID original.
CREATE OR REPLACE FUNCTION private.inventory_tenant_request_key_v1(
  p_organization_id uuid,
  p_request_id uuid
)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT md5('stomni:inventory-trace-receipt:v1:' || p_organization_id::text || ':' || p_request_id::text)::uuid
$$;
REVOKE ALL ON FUNCTION private.inventory_tenant_request_key_v1(uuid,uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.register_traceable_merchandise_receipt_v1(
  p_request_id uuid,
  p_product_id bigint,
  p_warehouse_id bigint,
  p_total_base_quantity numeric,
  p_received_at timestamptz,
  p_entry_type text,
  p_document text,
  p_supplier_id bigint,
  p_observations text,
  p_unit_cost numeric,
  p_unit_price numeric,
  p_box_price numeric,
  p_comparative_box_price numeric,
  p_allocations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_effective_request_id uuid;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para recibir inventario' USING ERRCODE='42501';
  END IF;

  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_product_id);
  PERFORM private.assert_warehouse_in_current_organization(p_warehouse_id);
  PERFORM private.assert_supplier_in_current_organization(p_supplier_id);

  -- Compatibilidad: si el tenant ya tiene una recepción creada antes de F9.2 con
  -- el UUID cliente literal, el retry sigue entrando con esa misma clave.
  IF EXISTS (
    SELECT 1
    FROM public.inventory_traceability_receipts
    WHERE organization_id=v_organization_id
      AND request_id=p_request_id
  ) THEN
    v_effective_request_id := p_request_id;
  ELSE
    v_effective_request_id := private.inventory_tenant_request_key_v1(
      v_organization_id,p_request_id
    );
  END IF;

  RETURN public._legacy_register_traceable_merchandise_receipt_v1(
    v_effective_request_id,p_product_id,p_warehouse_id,p_total_base_quantity,p_received_at,
    p_entry_type,p_document,p_supplier_id,p_observations,p_unit_cost,p_unit_price,
    p_box_price,p_comparative_box_price,p_allocations
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) TO authenticated;

COMMIT;
