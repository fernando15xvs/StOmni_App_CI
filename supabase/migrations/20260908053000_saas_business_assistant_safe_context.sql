-- Fase 6.4 SaaS: contexto empresarial seguro para asistente, sin SQL libre ni service_role global.
BEGIN;

CREATE TABLE public.business_assistant_settings (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  max_result_items integer NOT NULL DEFAULT 20 CHECK(max_result_items BETWEEN 1 AND 50),
  default_period_days integer NOT NULL DEFAULT 30 CHECK(default_period_days BETWEEN 1 AND 365),
  revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

INSERT INTO public.business_assistant_settings(organization_id)
SELECT id FROM public.organizations
ON CONFLICT(organization_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.create_default_business_assistant_settings()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO public.business_assistant_settings(organization_id)
  VALUES(NEW.id) ON CONFLICT(organization_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.create_default_business_assistant_settings() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER organizations_create_business_assistant_settings
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION private.create_default_business_assistant_settings();

ALTER TABLE public.business_assistant_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_assistant_settings FROM PUBLIC,anon,authenticated;
CREATE POLICY business_assistant_settings_tenant_read ON public.business_assistant_settings
FOR SELECT TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));

CREATE OR REPLACE FUNCTION public.get_business_assistant_settings_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.business_assistant_settings;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to read assistant settings';
  END IF;
  SELECT * INTO v_row FROM public.business_assistant_settings WHERE organization_id=v_org;
  RETURN jsonb_build_object(
    'enabled',v_row.enabled,'max_result_items',v_row.max_result_items,
    'default_period_days',v_row.default_period_days,'revision',v_row.revision
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_business_assistant_settings_v1(
  p_expected_revision bigint,p_enabled boolean,p_max_result_items integer,p_default_period_days integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.business_assistant_settings;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only tenant admin can configure business assistant';
  END IF;
  IF p_expected_revision IS NULL OR p_max_result_items NOT BETWEEN 1 AND 50
     OR p_default_period_days NOT BETWEEN 1 AND 365 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid assistant settings';
  END IF;
  UPDATE public.business_assistant_settings
  SET enabled=p_enabled,max_result_items=p_max_result_items,
      default_period_days=p_default_period_days,revision=revision+1,
      updated_at=clock_timestamp(),updated_by=auth.uid()
  WHERE organization_id=v_org AND revision=p_expected_revision
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Assistant settings changed concurrently';
  END IF;
  RETURN jsonb_build_object(
    'enabled',v_row.enabled,'max_result_items',v_row.max_result_items,
    'default_period_days',v_row.default_period_days,'revision',v_row.revision
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_business_assistant_context_v1(
  p_intent text,
  p_period_days integer DEFAULT NULL,
  p_branch_id uuid DEFAULT NULL,
  p_limit integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_settings public.business_assistant_settings;
  v_intent text:=lower(btrim(coalesce(p_intent,'')));
  v_days integer;
  v_limit integer;
  v_items jsonb:='[]'::jsonb;
  v_branch_name text;
  v_note text;
BEGIN
  IF NOT public.app_tiene_permiso('reports.view_profit') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to use business assistant context';
  END IF;
  SELECT * INTO v_settings FROM public.business_assistant_settings WHERE organization_id=v_org;
  IF NOT FOUND OR NOT v_settings.enabled THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Business assistant is disabled for this organization';
  END IF;

  IF v_intent NOT IN ('replenishment','non_moving_products','overdue_receivables','margin_diagnostics') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported business assistant intent';
  END IF;
  v_days:=coalesce(p_period_days,v_settings.default_period_days);
  v_limit:=coalesce(p_limit,v_settings.max_result_items);
  IF v_days NOT BETWEEN 1 AND 365 OR v_limit NOT BETWEEN 1 AND v_settings.max_result_items THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Assistant query limits are invalid';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT b.name INTO v_branch_name FROM public.branches b
    WHERE b.organization_id=v_org AND b.id=p_branch_id AND b.status='active';
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Branch not available in current organization';
    END IF;
  END IF;

  CASE v_intent
    WHEN 'replenishment' THEN
      SELECT coalesce(jsonb_agg(x.item ORDER BY x.priority DESC,x.name), '[]'::jsonb)
      INTO v_items
      FROM (
        SELECT p.nombre AS name,
          (coalesce(p.stock_minimo,0)-coalesce(sum(ia.cantidad),0))::numeric AS priority,
          jsonb_build_object(
            'product_id',p.id,'product_name',p.nombre,'stock_total',coalesce(sum(ia.cantidad),0),
            'stock_minimum',p.stock_minimo,
            'gap_to_minimum',greatest(coalesce(p.stock_minimo,0)-coalesce(sum(ia.cantidad),0),0),
            'supplier_id',p.proveedor_id
          ) AS item
        FROM public.productos p
        LEFT JOIN public.inventario_almacen ia
          ON ia.organization_id=p.organization_id AND ia.producto_id=p.id
        LEFT JOIN public.almacenes a
          ON a.organization_id=ia.organization_id AND a.id=ia.almacen_id
        WHERE p.organization_id=v_org AND coalesce(p.activo,true)
          AND coalesce(p.item_type,'stock_product')='stock_product'
          AND coalesce(p.stock_minimo,0)>0
          AND (p_branch_id IS NULL OR a.branch_id=p_branch_id)
        GROUP BY p.id,p.nombre,p.stock_minimo,p.proveedor_id
        HAVING coalesce(sum(ia.cantidad),0)<=p.stock_minimo
        ORDER BY priority DESC,p.nombre
        LIMIT v_limit
      ) x;
      v_note:='Sugerencias basadas en stock actual frente al mínimo configurado; no generan compras automáticamente.';

    WHEN 'non_moving_products' THEN
      SELECT coalesce(jsonb_agg(x.item ORDER BY x.stock_total DESC,x.product_name), '[]'::jsonb)
      INTO v_items
      FROM (
        SELECT p.nombre AS product_name,coalesce(sum(ia.cantidad),0)::numeric AS stock_total,
          jsonb_build_object(
            'product_id',p.id,'product_name',p.nombre,
            'stock_total',coalesce(sum(ia.cantidad),0),'days_without_exit_at_least',v_days,
            'supplier_id',p.proveedor_id
          ) AS item
        FROM public.productos p
        JOIN public.inventario_almacen ia
          ON ia.organization_id=p.organization_id AND ia.producto_id=p.id AND ia.cantidad>0
        JOIN public.almacenes a
          ON a.organization_id=ia.organization_id AND a.id=ia.almacen_id
        WHERE p.organization_id=v_org AND coalesce(p.activo,true)
          AND coalesce(p.item_type,'stock_product')='stock_product'
          AND (p_branch_id IS NULL OR a.branch_id=p_branch_id)
          AND NOT EXISTS(
            SELECT 1 FROM public.inventario_movimientos im
            JOIN public.almacenes am ON am.organization_id=im.organization_id AND am.id=im.almacen_id
            WHERE im.organization_id=v_org AND im.producto_id=p.id
              AND im.fecha>=clock_timestamp()-make_interval(days=>v_days)
              AND coalesce(im.salida_cant,0)>0
              AND (p_branch_id IS NULL OR am.branch_id=p_branch_id)
          )
        GROUP BY p.id,p.nombre,p.proveedor_id
        ORDER BY stock_total DESC,p.nombre
        LIMIT v_limit
      ) x;
      v_note:='Productos con stock positivo y sin salidas dentro del periodo analizado.';

    WHEN 'overdue_receivables' THEN
      SELECT coalesce(jsonb_agg(x.item ORDER BY x.balance DESC,x.sale_id), '[]'::jsonb)
      INTO v_items
      FROM (
        SELECT v.id AS sale_id,coalesce(v.saldo,0)::numeric AS balance,
          jsonb_build_object(
            'sale_id',v.id,'customer_id',v.cliente_id,'customer_name',coalesce(c.nombre,'Cliente'),
            'balance',v.saldo,'sale_date',v.fecha,'age_days',greatest(0,floor(extract(epoch from (clock_timestamp()-v.fecha))/86400))::integer
          ) AS item
        FROM public.ventas v
        LEFT JOIN public.clientes c ON c.organization_id=v.organization_id AND c.id=v.cliente_id
        WHERE v.organization_id=v_org AND v.estado='pendiente' AND coalesce(v.saldo,0)>0
          AND v.fecha<=clock_timestamp()-make_interval(days=>v_days)
          AND private.sale_belongs_unambiguously_to_branch(v_org,v.id,p_branch_id)
        ORDER BY balance DESC,v.id
        LIMIT v_limit
      ) x;
      v_note:='El esquema actual usa antigüedad de saldo pendiente; no existe una fecha contractual universal de vencimiento.';

    WHEN 'margin_diagnostics' THEN
      v_items:='[]'::jsonb;
      v_note:='Margen no disponible con rigor hasta persistir costo histórico inmutable por línea de venta. El asistente no usa precio_compra actual como sustituto.';
  END CASE;

  RETURN jsonb_build_object(
    'intent',v_intent,'organization_scope','current','branch_id',p_branch_id,
    'branch_name',v_branch_name,'period_days',v_days,'items',v_items,
    'note',v_note,'generated_at',clock_timestamp()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_business_assistant_settings_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_business_assistant_settings_v1(bigint,boolean,integer,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_business_assistant_context_v1(text,integer,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_business_assistant_settings_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_assistant_settings_v1(bigint,boolean,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_assistant_context_v1(text,integer,uuid,integer) TO authenticated;

COMMIT;
