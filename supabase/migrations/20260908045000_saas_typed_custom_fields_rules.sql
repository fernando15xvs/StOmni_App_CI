-- Fase 5.3 SaaS: campos y reglas configurables tipados, sin EAV por valor.
BEGIN;

-- Los valores viven junto a la entidad y viajan como un objeto JSONB compacto.
ALTER TABLE public.productos
  ADD COLUMN custom_fields jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.clientes
  ADD COLUMN custom_fields jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.proveedores
  ADD COLUMN custom_fields jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.productos
  ADD CONSTRAINT productos_custom_fields_object CHECK(jsonb_typeof(custom_fields)='object');
ALTER TABLE public.clientes
  ADD CONSTRAINT clientes_custom_fields_object CHECK(jsonb_typeof(custom_fields)='object');
ALTER TABLE public.proveedores
  ADD CONSTRAINT proveedores_custom_fields_object CHECK(jsonb_typeof(custom_fields)='object');

CREATE TABLE public.custom_field_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  entity_type text NOT NULL,
  code text NOT NULL,
  label text NOT NULL,
  value_type text NOT NULL,
  required boolean NOT NULL DEFAULT false,
  item_types text[] NOT NULL DEFAULT ARRAY[]::text[],
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  validation jsonb NOT NULL DEFAULT '{}'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT custom_field_definitions_organization_fkey
    FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE,
  CONSTRAINT custom_field_definitions_organization_id_key UNIQUE(organization_id,id),
  CONSTRAINT custom_field_definitions_entity_valid
    CHECK(entity_type IN ('catalog_item','customer','supplier')),
  CONSTRAINT custom_field_definitions_code_valid
    CHECK(code=lower(btrim(code)) AND code ~ '^[a-z][a-z0-9_]{0,47}$'),
  CONSTRAINT custom_field_definitions_label_valid
    CHECK(btrim(label)<>'' AND char_length(btrim(label))<=120),
  CONSTRAINT custom_field_definitions_type_valid
    CHECK(value_type IN ('text','number','boolean','date','select','multiselect')),
  CONSTRAINT custom_field_definitions_options_array CHECK(jsonb_typeof(options)='array'),
  CONSTRAINT custom_field_definitions_validation_object CHECK(jsonb_typeof(validation)='object'),
  CONSTRAINT custom_field_definitions_sort_order_valid CHECK(sort_order BETWEEN 0 AND 10000),
  CONSTRAINT custom_field_definitions_status_valid CHECK(status IN ('active','inactive'))
);
CREATE UNIQUE INDEX custom_field_definitions_code_key
  ON public.custom_field_definitions(organization_id,entity_type,code);
CREATE INDEX custom_field_definitions_runtime_idx
  ON public.custom_field_definitions(organization_id,entity_type,status,sort_order,code);

ALTER TABLE public.custom_field_definitions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.custom_field_definitions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.custom_field_definitions TO authenticated;
CREATE POLICY custom_field_definitions_tenant_select ON public.custom_field_definitions
FOR SELECT TO authenticated
USING(private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

-- -----------------------------------------------------------------------------
-- Validadores puros. No usan SQL dinámico ni ejecutan expresiones configuradas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.custom_field_definition_is_valid(
  p_entity_type text,
  p_value_type text,
  p_item_types text[],
  p_options jsonb,
  p_validation jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_key text;
  v_option jsonb;
BEGIN
  IF p_entity_type NOT IN ('catalog_item','customer','supplier')
     OR p_value_type NOT IN ('text','number','boolean','date','select','multiselect')
     OR p_options IS NULL OR jsonb_typeof(p_options)<>'array'
     OR p_validation IS NULL OR jsonb_typeof(p_validation)<>'object' THEN
    RETURN false;
  END IF;

  IF p_entity_type<>'catalog_item' AND COALESCE(cardinality(p_item_types),0)<>0 THEN RETURN false; END IF;
  IF EXISTS(
    SELECT 1 FROM unnest(COALESCE(p_item_types,ARRAY[]::text[])) x
    WHERE x NOT IN ('stock_product','non_stock_product','service','bundle')
  ) THEN RETURN false; END IF;

  IF p_value_type IN ('select','multiselect') THEN
    IF jsonb_array_length(p_options)=0 THEN RETURN false; END IF;
    FOR v_option IN SELECT value FROM jsonb_array_elements(p_options)
    LOOP
      IF jsonb_typeof(v_option)<>'string' OR btrim(v_option #>> '{}')='' OR char_length(v_option #>> '{}')>120 THEN
        RETURN false;
      END IF;
    END LOOP;
    IF (SELECT count(*) FROM jsonb_array_elements_text(p_options))
       <> (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_options) value) THEN
      RETURN false;
    END IF;
  ELSIF jsonb_array_length(p_options)<>0 THEN
    RETURN false;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_validation)
  LOOP
    IF v_key NOT IN ('min','max','min_length','max_length','pattern') THEN RETURN false; END IF;
  END LOOP;
  IF p_validation ? 'min' AND jsonb_typeof(p_validation->'min')<>'number' THEN RETURN false; END IF;
  IF p_validation ? 'max' AND jsonb_typeof(p_validation->'max')<>'number' THEN RETURN false; END IF;
  IF p_validation ? 'min_length' AND (
    jsonb_typeof(p_validation->'min_length')<>'number'
    OR (p_validation->>'min_length')::numeric<>trunc((p_validation->>'min_length')::numeric)
    OR (p_validation->>'min_length')::integer<0
  ) THEN RETURN false; END IF;
  IF p_validation ? 'max_length' AND (
    jsonb_typeof(p_validation->'max_length')<>'number'
    OR (p_validation->>'max_length')::numeric<>trunc((p_validation->>'max_length')::numeric)
    OR (p_validation->>'max_length')::integer<0
  ) THEN RETURN false; END IF;
  IF p_validation ? 'pattern' AND (
    jsonb_typeof(p_validation->'pattern')<>'string'
    OR char_length(p_validation->>'pattern')>240
  ) THEN RETURN false; END IF;
  IF p_value_type NOT IN ('number') AND (p_validation ? 'min' OR p_validation ? 'max') THEN RETURN false; END IF;
  IF p_value_type NOT IN ('text') AND (p_validation ? 'min_length' OR p_validation ? 'max_length' OR p_validation ? 'pattern') THEN RETURN false; END IF;
  IF p_validation ? 'min' AND p_validation ? 'max'
     AND (p_validation->>'min')::numeric>(p_validation->>'max')::numeric THEN RETURN false; END IF;
  IF p_validation ? 'min_length' AND p_validation ? 'max_length'
     AND (p_validation->>'min_length')::integer>(p_validation->>'max_length')::integer THEN RETURN false; END IF;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION private.custom_field_value_is_valid(
  p_value jsonb,
  p_value_type text,
  p_options jsonb,
  p_validation jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_text text;
  v_number numeric;
  v_item jsonb;
BEGIN
  IF p_value IS NULL OR p_value='null'::jsonb THEN RETURN true; END IF;
  CASE p_value_type
    WHEN 'text' THEN
      IF jsonb_typeof(p_value)<>'string' THEN RETURN false; END IF;
      v_text:=p_value #>> '{}';
      IF p_validation ? 'min_length' AND char_length(v_text)<(p_validation->>'min_length')::integer THEN RETURN false; END IF;
      IF p_validation ? 'max_length' AND char_length(v_text)>(p_validation->>'max_length')::integer THEN RETURN false; END IF;
      IF p_validation ? 'pattern' AND v_text !~ (p_validation->>'pattern') THEN RETURN false; END IF;
    WHEN 'number' THEN
      IF jsonb_typeof(p_value)<>'number' THEN RETURN false; END IF;
      v_number:=(p_value #>> '{}')::numeric;
      IF p_validation ? 'min' AND v_number<(p_validation->>'min')::numeric THEN RETURN false; END IF;
      IF p_validation ? 'max' AND v_number>(p_validation->>'max')::numeric THEN RETURN false; END IF;
    WHEN 'boolean' THEN
      IF jsonb_typeof(p_value)<>'boolean' THEN RETURN false; END IF;
    WHEN 'date' THEN
      IF jsonb_typeof(p_value)<>'string' OR (p_value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN false; END IF;
      PERFORM (p_value #>> '{}')::date;
    WHEN 'select' THEN
      IF jsonb_typeof(p_value)<>'string' OR NOT (p_options ? (p_value #>> '{}')) THEN RETURN false; END IF;
    WHEN 'multiselect' THEN
      IF jsonb_typeof(p_value)<>'array' THEN RETURN false; END IF;
      FOR v_item IN SELECT value FROM jsonb_array_elements(p_value)
      LOOP
        IF jsonb_typeof(v_item)<>'string' OR NOT (p_options ? (v_item #>> '{}')) THEN RETURN false; END IF;
      END LOOP;
    ELSE RETURN false;
  END CASE;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION private.custom_field_definition_is_valid(text,text,text[],jsonb,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.custom_field_value_is_valid(jsonb,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- Trigger universal por entidad. TG_ARGV[0] contiene el tipo de entidad.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.validate_entity_custom_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=NEW.organization_id;
  v_entity_type text:=TG_ARGV[0];
  v_values jsonb:=COALESCE(NEW.custom_fields,'{}'::jsonb);
  v_item_type text:=CASE WHEN v_entity_type='catalog_item' THEN NEW.item_type ELSE NULL END;
  v_key text;
  v_def public.custom_field_definitions%ROWTYPE;
  v_value jsonb;
BEGIN
  IF jsonb_typeof(v_values)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='custom_fields must be a JSON object';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(v_values)
  LOOP
    SELECT * INTO v_def
    FROM public.custom_field_definitions d
    WHERE d.organization_id=v_org AND d.entity_type=v_entity_type AND d.code=v_key;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE=format('Unknown custom field: %s',v_key);
    END IF;
    IF v_entity_type='catalog_item' AND cardinality(v_def.item_types)>0
       AND NOT (v_item_type=ANY(v_def.item_types)) THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE=format('Custom field %s does not apply to this item type',v_key);
    END IF;
    v_value:=v_values->v_key;
    IF NOT private.custom_field_value_is_valid(v_value,v_def.value_type,v_def.options,v_def.validation) THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE=format('Invalid value for custom field: %s',v_key);
    END IF;
  END LOOP;

  FOR v_def IN
    SELECT * FROM public.custom_field_definitions d
    WHERE d.organization_id=v_org AND d.entity_type=v_entity_type
      AND d.status='active' AND d.required
      AND (v_entity_type<>'catalog_item' OR cardinality(d.item_types)=0 OR v_item_type=ANY(d.item_types))
  LOOP
    IF NOT (v_values ? v_def.code) OR v_values->v_def.code='null'::jsonb
       OR (v_def.value_type IN ('text','select') AND btrim(v_values->>v_def.code)='')
       OR (v_def.value_type='multiselect' AND jsonb_array_length(v_values->v_def.code)=0) THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE=format('Required custom field missing: %s',v_def.code);
    END IF;
  END LOOP;
  NEW.custom_fields:=v_values;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.validate_entity_custom_fields() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER productos_validate_custom_fields
BEFORE INSERT OR UPDATE OF custom_fields,item_type ON public.productos
FOR EACH ROW EXECUTE FUNCTION private.validate_entity_custom_fields('catalog_item');
CREATE TRIGGER clientes_validate_custom_fields
BEFORE INSERT OR UPDATE OF custom_fields ON public.clientes
FOR EACH ROW EXECUTE FUNCTION private.validate_entity_custom_fields('customer');
CREATE TRIGGER proveedores_validate_custom_fields
BEFORE INSERT OR UPDATE OF custom_fields ON public.proveedores
FOR EACH ROW EXECUTE FUNCTION private.validate_entity_custom_fields('supplier');

-- -----------------------------------------------------------------------------
-- RPC de definiciones. Cambiar una definición valida los valores existentes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_custom_field_definitions_v1(
  p_entity_type text,
  p_include_inactive boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_entity text:=lower(btrim(COALESCE(p_entity_type,'')));
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant read permission required';
  END IF;
  IF v_entity NOT IN ('catalog_item','customer','supplier') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported custom-field entity type';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.sort_order,d.code),'[]'::jsonb)
  INTO v_result
  FROM public.custom_field_definitions d
  WHERE d.organization_id=v_org AND d.entity_type=v_entity
    AND (COALESCE(p_include_inactive,false) OR d.status='active');
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_custom_field_definition_v1(
  p_definition_id uuid,
  p_entity_type text,
  p_code text,
  p_label text,
  p_value_type text,
  p_required boolean,
  p_item_types text[],
  p_options jsonb,
  p_validation jsonb,
  p_sort_order integer,
  p_status text DEFAULT 'active'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_entity text:=lower(btrim(COALESCE(p_entity_type,'')));
  v_code text:=lower(btrim(COALESCE(p_code,'')));
  v_label text:=btrim(COALESCE(p_label,''));
  v_type text:=lower(btrim(COALESCE(p_value_type,'')));
  v_items text[]:=COALESCE(p_item_types,ARRAY[]::text[]);
  v_options jsonb:=COALESCE(p_options,'[]'::jsonb);
  v_validation jsonb:=COALESCE(p_validation,'{}'::jsonb);
  v_status text:=lower(btrim(COALESCE(p_status,'active')));
  v_id uuid:=COALESCE(p_definition_id,gen_random_uuid());
  v_existing public.custom_field_definitions%ROWTYPE;
  v_row public.custom_field_definitions%ROWTYPE;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant administrator permission required';
  END IF;
  IF v_code !~ '^[a-z][a-z0-9_]{0,47}$' OR v_label='' OR char_length(v_label)>120
     OR COALESCE(p_sort_order,0) NOT BETWEEN 0 AND 10000 OR v_status NOT IN ('active','inactive')
     OR NOT private.custom_field_definition_is_valid(v_entity,v_type,v_items,v_options,v_validation) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid custom field definition';
  END IF;

  IF p_definition_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.custom_field_definitions
    WHERE organization_id=v_org AND id=p_definition_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Custom field definition not available in current organization'; END IF;
    IF v_existing.entity_type<>v_entity OR v_existing.code<>v_code THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Custom field entity/code are immutable';
    END IF;
  END IF;

  -- Un requerido sólo se activa cuando todas las filas aplicables ya tienen
  -- un valor válido. Permite rollout: crear opcional -> poblar -> exigir.
  IF COALESCE(p_required,false) THEN
    IF v_entity='catalog_item' AND EXISTS(
      SELECT 1 FROM public.productos x
      WHERE x.organization_id=v_org
        AND (cardinality(v_items)=0 OR x.item_type=ANY(v_items))
        AND (
          NOT (x.custom_fields ? v_code)
          OR x.custom_fields->v_code='null'::jsonb
          OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
        )
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
    IF v_entity='customer' AND EXISTS(
      SELECT 1 FROM public.clientes x WHERE x.organization_id=v_org AND (
        NOT (x.custom_fields ? v_code) OR x.custom_fields->v_code='null'::jsonb
        OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
      )
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
    IF v_entity='supplier' AND EXISTS(
      SELECT 1 FROM public.proveedores x WHERE x.organization_id=v_org AND (
        NOT (x.custom_fields ? v_code) OR x.custom_fields->v_code='null'::jsonb
        OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
      )
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
  END IF;

  -- Cambios de tipo/opciones/reglas tampoco pueden invalidar valores presentes.
  IF v_entity='catalog_item' AND EXISTS(
    SELECT 1 FROM public.productos x WHERE x.organization_id=v_org AND x.custom_fields ? v_code
      AND (cardinality(v_items)=0 OR x.item_type=ANY(v_items))
      AND NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
  ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Definition change would invalidate existing catalog values'; END IF;
  IF v_entity='customer' AND EXISTS(
    SELECT 1 FROM public.clientes x WHERE x.organization_id=v_org AND x.custom_fields ? v_code
      AND NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
  ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Definition change would invalidate existing customer values'; END IF;
  IF v_entity='supplier' AND EXISTS(
    SELECT 1 FROM public.proveedores x WHERE x.organization_id=v_org AND x.custom_fields ? v_code
      AND NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation)
  ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Definition change would invalidate existing supplier values'; END IF;

  INSERT INTO public.custom_field_definitions(
    id,organization_id,entity_type,code,label,value_type,required,item_types,
    options,validation,sort_order,status
  ) VALUES(
    v_id,v_org,v_entity,v_code,v_label,v_type,COALESCE(p_required,false),v_items,
    v_options,v_validation,COALESCE(p_sort_order,0),v_status
  )
  ON CONFLICT(id) DO UPDATE SET
    label=EXCLUDED.label,value_type=EXCLUDED.value_type,required=EXCLUDED.required,
    item_types=EXCLUDED.item_types,options=EXCLUDED.options,validation=EXCLUDED.validation,
    sort_order=EXCLUDED.sort_order,status=EXCLUDED.status,updated_at=clock_timestamp()
  WHERE public.custom_field_definitions.organization_id=v_org
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant custom field update rejected'; END IF;
  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_entity_custom_fields_v1(
  p_entity_type text,
  p_entity_id bigint,
  p_values jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_entity text:=lower(btrim(COALESCE(p_entity_type,'')));
  v_values jsonb:=COALESCE(p_values,'{}'::jsonb);
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  IF p_entity_id IS NULL OR jsonb_typeof(v_values)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid custom-field update payload';
  END IF;
  IF v_entity='catalog_item' THEN
    UPDATE public.productos SET custom_fields=v_values
    WHERE organization_id=v_org AND id=p_entity_id
    RETURNING custom_fields INTO v_result;
  ELSIF v_entity='customer' THEN
    UPDATE public.clientes SET custom_fields=v_values
    WHERE organization_id=v_org AND id=p_entity_id
    RETURNING custom_fields INTO v_result;
  ELSIF v_entity='supplier' THEN
    UPDATE public.proveedores SET custom_fields=v_values
    WHERE organization_id=v_org AND id=p_entity_id
    RETURNING custom_fields INTO v_result;
  ELSE
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported custom-field entity type';
  END IF;
  IF v_result IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Entity not available in current organization'; END IF;
  RETURN jsonb_build_object('entity_type',v_entity,'entity_id',p_entity_id,'custom_fields',v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.list_custom_field_definitions_v1(text,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_entity_custom_fields_v1(text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_custom_field_definitions_v1(text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_entity_custom_fields_v1(text,bigint,jsonb) TO authenticated;

COMMIT;