-- F5.3: en productos, item_type debe estar normalizado antes de decidir qué
-- definiciones custom aplican (especialmente save_service_v1 legacy).
BEGIN;
DROP TRIGGER IF EXISTS productos_validate_custom_fields ON public.productos;
DROP TRIGGER IF EXISTS zzz_productos_validate_custom_fields ON public.productos;
CREATE TRIGGER zzz_productos_validate_custom_fields
BEFORE INSERT OR UPDATE OF custom_fields,item_type,es_servicio ON public.productos
FOR EACH ROW EXECUTE FUNCTION private.validate_entity_custom_fields('catalog_item');
COMMIT;