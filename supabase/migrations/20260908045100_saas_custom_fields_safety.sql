-- Fase 5.3 correcciones de seguridad y compatibilidad de trigger universal.
BEGIN;

-- Reglas declarativas V1 deliberadamente acotadas: sin regex/expresiones ejecutables.
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
    IF jsonb_array_length(p_options)=0 OR jsonb_array_length(p_options)>100 THEN RETURN false; END IF;
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
    IF v_key NOT IN ('min','max','min_length','max_length') THEN RETURN false; END IF;
  END LOOP;
  IF p_validation ? 'min' AND jsonb_typeof(p_validation->'min')<>'number' THEN RETURN false; END IF;
  IF p_validation ? 'max' AND jsonb_typeof(p_validation->'max')<>'number' THEN RETURN false; END IF;
  IF p_validation ? 'min_length' AND (
    jsonb_typeof(p_validation->'min_length')<>'number'
    OR (p_validation->>'min_length')::numeric<>trunc((p_validation->>'min_length')::numeric)
    OR (p_validation->>'min_length')::integer<0
    OR (p_validation->>'min_length')::integer>4000
  ) THEN RETURN false; END IF;
  IF p_validation ? 'max_length' AND (
    jsonb_typeof(p_validation->'max_length')<>'number'
    OR (p_validation->>'max_length')::numeric<>trunc((p_validation->>'max_length')::numeric)
    OR (p_validation->>'max_length')::integer<0
    OR (p_validation->>'max_length')::integer>4000
  ) THEN RETURN false; END IF;
  IF p_value_type<>'number' AND (p_validation ? 'min' OR p_validation ? 'max') THEN RETURN false; END IF;
  IF p_value_type<>'text' AND (p_validation ? 'min_length' OR p_validation ? 'max_length') THEN RETURN false; END IF;
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
  v_seen text[]:=ARRAY[]::text[];
BEGIN
  IF p_value IS NULL OR p_value='null'::jsonb THEN RETURN true; END IF;
  CASE p_value_type
    WHEN 'text' THEN
      IF jsonb_typeof(p_value)<>'string' THEN RETURN false; END IF;
      v_text:=p_value #>> '{}';
      IF char_length(v_text)>4000 THEN RETURN false; END IF;
      IF p_validation ? 'min_length' AND char_length(v_text)<(p_validation->>'min_length')::integer THEN RETURN false; END IF;
      IF p_validation ? 'max_length' AND char_length(v_text)>(p_validation->>'max_length')::integer THEN RETURN false; END IF;
    WHEN 'number' THEN
      IF jsonb_typeof(p_value)<>'number' THEN RETURN false; END IF;
      v_number:=(p_value #>> '{}')::numeric;
      IF p_validation ? 'min' AND v_number<(p_validation->>'min')::numeric THEN RETURN false; END IF;
      IF p_validation ? 'max' AND v_number>(p_validation->>'max')::numeric THEN RETURN false; END IF;
    WHEN 'boolean' THEN
      IF jsonb_typeof(p_value)<>'boolean' THEN RETURN false; END IF;
    WHEN 'date' THEN
      IF jsonb_typeof(p_value)<>'string' OR (p_value #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RETURN false; END IF;
      PERFORM (p_value #>> '{}')::date;
    WHEN 'select' THEN
      IF jsonb_typeof(p_value)<>'string' OR NOT (p_options ? (p_value #>> '{}')) THEN RETURN false; END IF;
    WHEN 'multiselect' THEN
      IF jsonb_typeof(p_value)<>'array' OR jsonb_array_length(p_value)>100 THEN RETURN false; END IF;
      FOR v_item IN SELECT value FROM jsonb_array_elements(p_value)
      LOOP
        IF jsonb_typeof(v_item)<>'string' OR NOT (p_options ? (v_item #>> '{}'))
           OR (v_item #>> '{}')=ANY(v_seen) THEN RETURN false; END IF;
        v_seen:=array_append(v_seen,v_item #>> '{}');
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

-- to_jsonb(NEW) permite reutilizar el mismo trigger en tablas con layouts distintos.
CREATE OR REPLACE FUNCTION private.validate_entity_custom_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row jsonb:=to_jsonb(NEW);
  v_org uuid:=NULLIF(v_row->>'organization_id','')::uuid;
  v_entity_type text:=TG_ARGV[0];
  v_values jsonb:=COALESCE(v_row->'custom_fields','{}'::jsonb);
  v_item_type text:=CASE WHEN v_entity_type='catalog_item' THEN v_row->>'item_type' ELSE NULL END;
  v_key text;
  v_def public.custom_field_definitions%ROWTYPE;
  v_value jsonb;
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION USING ERRCODE='23502', MESSAGE='organization_id required before validating custom fields'; END IF;
  IF jsonb_typeof(v_values)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='custom_fields must be a JSON object';
  END IF;
  IF pg_column_size(v_values)>65536 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='custom_fields payload exceeds 64 KiB limit';
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

-- Una nueva restricción por item_type no puede dejar valores existentes fuera de alcance.
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

  IF v_entity='catalog_item' AND cardinality(v_items)>0 AND EXISTS(
    SELECT 1 FROM public.productos x
    WHERE x.organization_id=v_org AND x.custom_fields ? v_code AND NOT (x.item_type=ANY(v_items))
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Remove existing values before restricting custom field to other item types';
  END IF;

  IF COALESCE(p_required,false) THEN
    IF v_entity='catalog_item' AND EXISTS(
      SELECT 1 FROM public.productos x
      WHERE x.organization_id=v_org AND (cardinality(v_items)=0 OR x.item_type=ANY(v_items))
        AND (NOT (x.custom_fields ? v_code) OR x.custom_fields->v_code='null'::jsonb
          OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation))
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
    IF v_entity='customer' AND EXISTS(
      SELECT 1 FROM public.clientes x WHERE x.organization_id=v_org AND (
        NOT (x.custom_fields ? v_code) OR x.custom_fields->v_code='null'::jsonb
        OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation))
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
    IF v_entity='supplier' AND EXISTS(
      SELECT 1 FROM public.proveedores x WHERE x.organization_id=v_org AND (
        NOT (x.custom_fields ? v_code) OR x.custom_fields->v_code='null'::jsonb
        OR NOT private.custom_field_value_is_valid(x.custom_fields->v_code,v_type,v_options,v_validation))
    ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Populate valid values before making custom field required'; END IF;
  END IF;

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
REVOKE ALL ON FUNCTION public.upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text) TO authenticated;

COMMIT;