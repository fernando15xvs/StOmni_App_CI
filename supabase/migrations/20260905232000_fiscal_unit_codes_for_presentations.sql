BEGIN;

CREATE OR REPLACE FUNCTION public._validate_product_unit_fiscal_codes_v1(
  p_profile jsonb
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_row jsonb;
  v_code text;
BEGIN
  IF jsonb_typeof(p_profile) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_profile->'presentations') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_profile->'presentations') LOOP
    IF v_row ? 'fiscal_unit_code' THEN
      IF jsonb_typeof(v_row->'fiscal_unit_code') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'El código fiscal de la presentación debe ser texto';
      END IF;
      v_code := upper(trim(v_row->>'fiscal_unit_code'));
      IF v_code = '' OR v_code !~ '^[A-Z0-9]{1,6}$'
         OR v_code <> v_row->>'fiscal_unit_code' THEN
        RAISE EXCEPTION 'Código fiscal de unidad inválido para la presentación %',
          COALESCE(v_row->>'code', '?');
      END IF;
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v6(
  p_product_id bigint,
  p_expected_revision bigint,
  p_profile jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  PERFORM public._validate_product_unit_fiscal_codes_v1(p_profile);
  RETURN public.save_product_unit_profile_v5(
    p_product_id,
    p_expected_revision,
    p_profile
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._validate_product_unit_fiscal_codes_v1(jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb)
  TO authenticated;

COMMIT;
