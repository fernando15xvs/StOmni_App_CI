-- Métricas configurables sobre un catálogo cerrado de fuentes; nunca SQL libre.
BEGIN;

CREATE TABLE public.business_metric_definitions (
  business_id bigint NOT NULL REFERENCES public.configuracion_negocio(id),
  source_key text NOT NULL CHECK(source_key IN (
    'income','expenses','net_cash_flow','discounts','sales_count',
    'inventory_entries','inventory_exits'
  )),
  label text NOT NULL CHECK(length(trim(label)) BETWEEN 1 AND 80),
  position integer NOT NULL CHECK(position BETWEEN 0 AND 100),
  enabled boolean NOT NULL DEFAULT true,
  format text NOT NULL CHECK(format IN ('currency','number')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(business_id,source_key),
  UNIQUE(business_id,position)
);

ALTER TABLE public.business_metric_definitions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_metric_definitions FROM PUBLIC,anon,authenticated;

INSERT INTO public.business_metric_definitions(
  business_id,source_key,label,position,enabled,format
)
SELECT 1,source_key,label,position,true,format
FROM (VALUES
  ('income','Ingresos',0,'currency'),
  ('expenses','Gastos',1,'currency'),
  ('net_cash_flow','Flujo neto',2,'currency'),
  ('discounts','Descuentos',3,'currency'),
  ('sales_count','Ventas',4,'number'),
  ('inventory_entries','Entradas de inventario',5,'number'),
  ('inventory_exits','Salidas de inventario',6,'number')
) AS d(source_key,label,position,format)
WHERE EXISTS(SELECT 1 FROM public.configuracion_negocio WHERE id=1)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.list_business_metrics_v1()
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_row public.business_metric_definitions%ROWTYPE;
BEGIN
  IF NOT public.app_tiene_permiso('reports.view_profit') THEN
    RAISE EXCEPTION 'No autorizado para consultar métricas' USING ERRCODE='42501';
  END IF;
  FOR v_row IN
    SELECT * FROM public.business_metric_definitions
    WHERE business_id=1 ORDER BY position,source_key
  LOOP
    RETURN NEXT jsonb_build_object(
      'source',v_row.source_key,'label',v_row.label,'position',v_row.position,
      'enabled',v_row.enabled,'format',v_row.format
    );
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_business_metrics_v1(p_definitions jsonb)
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_row jsonb;
  v_sources text[]:=ARRAY[]::text[];
  v_positions integer[]:=ARRAY[]::integer[];
  v_source text;
  v_label text;
  v_position integer;
  v_enabled boolean;
  v_format text;
BEGIN
  IF NOT public.app_tiene_permiso('business.configure') THEN
    RAISE EXCEPTION 'No autorizado para configurar métricas' USING ERRCODE='42501';
  END IF;
  IF p_definitions IS NULL OR jsonb_typeof(p_definitions)<>'array'
     OR jsonb_array_length(p_definitions)>7 THEN
    RAISE EXCEPTION 'Configuración de métricas inválida' USING ERRCODE='22023';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_definitions) LOOP
    v_source:=trim(coalesce(v_row->>'source',''));
    v_label:=trim(coalesce(v_row->>'label',''));
    v_position:=NULLIF(v_row->>'position','')::integer;
    v_enabled:=NULLIF(v_row->>'enabled','')::boolean;
    v_format:=trim(coalesce(v_row->>'format',''));
    IF v_source NOT IN ('income','expenses','net_cash_flow','discounts','sales_count','inventory_entries','inventory_exits')
       OR v_source=ANY(v_sources) OR v_label='' OR length(v_label)>80
       OR v_position IS NULL OR v_position NOT BETWEEN 0 AND 100
       OR v_position=ANY(v_positions) OR v_enabled IS NULL
       OR v_format NOT IN ('currency','number') THEN
      RAISE EXCEPTION 'Definición de métrica inválida o duplicada' USING ERRCODE='22023';
    END IF;
    v_sources:=array_append(v_sources,v_source);
    v_positions:=array_append(v_positions,v_position);
  END LOOP;

  DELETE FROM public.business_metric_definitions WHERE business_id=1;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_definitions) LOOP
    INSERT INTO public.business_metric_definitions(
      business_id,source_key,label,position,enabled,format
    ) VALUES(
      1,trim(v_row->>'source'),trim(v_row->>'label'),
      (v_row->>'position')::integer,(v_row->>'enabled')::boolean,trim(v_row->>'format')
    );
  END LOOP;

  RETURN QUERY SELECT * FROM public.list_business_metrics_v1();
END;
$function$;

REVOKE ALL ON FUNCTION public.list_business_metrics_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_business_metrics_v1(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_business_metrics_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_business_metrics_v1(jsonb) TO authenticated;

COMMIT;
