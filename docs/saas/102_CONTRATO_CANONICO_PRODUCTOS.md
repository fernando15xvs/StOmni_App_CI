# Contrato canónico de productos — StOmni

Fecha de decisión: 2026-09-22.

## Premisa

StOmni es una aplicación nueva. No existen datos productivos ni usuarios reales que obliguen a conservar aliases históricos. Las migraciones antiguas se mantienen intactas como evidencia, pero el estado efectivo del sistema usa un único contrato vigente.

## Tipo de venta

`tipo_venta` es una clasificación de topología comercial y sólo admite:

| Código DB | Unidad base de inventario | Venta permitida |
| --- | --- | --- |
| `UNIDAD` | unidad | unidades |
| `CAJA` | caja | cajas |
| `PAQUETE` | paquete | paquetes |
| `CAJA_PAQUETES` | paquete | cajas y paquetes |
| `CAJA_UNIDADES` | unidad | cajas y unidades |

No se aceptan `AMBOS`, `SOLO_CAJAS`, `SOLO_UNIDADES`, `CAJA_UNIDAD`, `CAJAS_UNIDADES`, `PAQUETES` ni variantes de mayúsculas/minúsculas como valores persistidos.

`SaleUnitType` es la representación Dart de esos cinco códigos. El parser es fail-fast: un código ausente o no canónico es un error de contrato.

## Presentaciones configurables

`ProductUnitProfile` describe presentaciones, factores, etiquetas, precisión y código fiscal. Es un concepto distinto de la topología `tipo_venta` y no crea aliases alternativos para ella.

El único documento persistido aceptado es `schema_version: 2`. No se genera ni se acepta schema v1.

## Cantidades y stock mínimo

El inventario físico se persiste como entero. Cuando la unidad base tiene precisión decimal, `ProductUnitConfiguration.storageScale` convierte cantidades visibles a unidades menores enteras.

`stock_minimo` sigue el mismo contrato: se almacena como entero escalado. La UI trabaja con el valor visible y el boundary de guardado lo convierte antes de llamar a SQL.

## Writers

Los únicos writers de producto deben emitir el contrato canónico:

- `crear_producto_con_stock`
- `actualizar_producto_seguro_v1`
- `save_service_v1` (los servicios usan `UNIDAD`; `item_type` distingue su naturaleza)

La tabla `productos` tiene un `CHECK` que impide cualquier alias, aunque un writer defectuoso intente insertarlo.

## Política de evolución

No se editan migraciones históricas. Cualquier evolución del contrato se hace con una migración nueva, actualizando en el mismo candidato Dart, SQL, Edge Functions, scripts y tests. No se introduce compatibilidad silenciosa salvo que exista una necesidad productiva real y documentada.
