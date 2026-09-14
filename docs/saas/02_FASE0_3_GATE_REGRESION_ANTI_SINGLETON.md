# Fase 0.3 — Gate de regresión y anti-singleton

Estado: **CERRADA / AUDITADA**  
Rama: `feature/saas-multitenant-foundation`

## Objetivo

Impedir que, mientras se migra StOmni a multi-tenant, se introduzcan nuevas dependencias del modelo singleton existente (`businessId = '1'`, `business_id = 1`, `configuracion_negocio.id = 1` o «tomar la primera empresa»).

El gate conserva temporalmente la deuda legacy ya inventariada, pero la congela: no puede crecer silenciosamente.

---

## 1. Implementación

Se añadió:

```text
scripts/verify_no_new_singletons.mjs
```

Commit de implementación:

```text
adfd9aa0583713a63f218c6b6c5edabb312c4cf2
```

También se conectó al workflow existente en:

```text
.github/workflows/flutter_ci.yml
```

Commit de integración:

```text
f41c47cdceec6d19d3209fa5a97f3055d16c75d7
```

La rama `feature/saas-multitenant-foundation` **no fue agregada a los triggers del workflow**, por lo que esta fase no fuerza ni consume una ejecución de GitHub Actions.

---

## 2. Superficie vigilada

El gate inspecciona código ejecutable en:

- `apps/*/lib/**`;
- `packages/*/lib/**`;
- `supabase/functions/**`.

No usa un grep genérico del literal `1`, porque en StOmni existen usos válidos como tipo de documento DNI, cantidades, correlativos y estados.

Se detectan específicamente patrones que representan tenant singleton, entre ellos:

- `businessId: '1'` y comparaciones equivalentes;
- constante legacy de business ID fija en `1`;
- fallback de `businessId` a `1`;
- perfil que sólo acepta `business_id = 1`;
- consulta a `configuracion_negocio` con `.eq('id', 1)`;
- consulta a `configuracion_negocio` ordenada por ID y limitada a la primera fila;
- cache de perfil hardcodeada al tenant `1`;
- nuevos usos equivalentes de `business_id = 1`.

Archivos Dart generados (`*.g.dart`, `*.freezed.dart`) y directorios de build/cache no se consideran fuente arquitectónica.

---

## 3. Baseline runtime legacy congelado

Los siete archivos ejecutables conocidos con singleton quedaron fijados por Git blob SHA:

| Archivo | Blob SHA baseline |
|---|---|
| `packages/core_logic/lib/services/configuracion_service.dart` | `3e0c555331f73dcfefb624d9188253d6e6ee87a0` |
| `packages/core_logic/lib/business/data/business_profile_mapper.dart` | `da439ad8a768e2dcd6ffee14710d12f5b7c97db1` |
| `packages/core_logic/lib/business/data/supabase_business_profile_gateway.dart` | `5eb2c0d48001ab6a76f5e71d8a5ca64c813d08df` |
| `packages/core_logic/lib/features/facturacion/application/business_fiscal_profile_mapper.dart` | `ab755fb0be696876432dd236169a3668da937d0c` |
| `packages/core_logic/lib/features/facturacion/data/guias_remision_repository.dart` | `c0800d1d7478da0965502cc1886541afc1f59401` |
| `supabase/functions/_shared/proceso_tributario_common.ts` | `daedc9e7027f07ec25af3f4f4f12c31bdcd6315b` |
| `supabase/functions/_shared/guia_remision_common.ts` | `bdd2b6d7a2c5ea46391e892952cf8c819ae61706` |

Regla:

- si un archivo nuevo introduce un patrón singleton: **FAIL**;
- si uno de estos siete archivos cambia y todavía conserva un patrón singleton: **FAIL**;
- si la dependencia singleton se elimina por completo: el gate permite el cambio y avisa que el baseline ya puede limpiarse.

Esto evita que una refactorización aparentemente inocente amplíe la deuda legacy.

---

## 4. Baseline de migraciones SQL

Última migración histórica aceptada antes del gate:

```text
20260907003926_storage_buckets_and_policies.sql
```

Toda migración SQL raíz posterior se inspecciona.

Se bloquean, entre otros:

- `business_id = 1`;
- `configuracion_negocio ... WHERE id = 1`;
- `configuracion_negocio ... ORDER BY id ... LIMIT 1`;
- nuevas relaciones `business_id -> configuracion_negocio(id)` que perpetúen el modelo de tenant legacy.

### Excepción controlada de backfill

Una migración de transición puede necesitar leer explícitamente el registro singleton histórico para backfillear datos a la nueva organización.

Sólo en ese caso se admite la marca exacta:

```sql
-- saas-legacy-singleton-exception: legacy-backfill
```

La excepción genera warning y no está permitida como arquitectura runtime ni como modelo final. Su finalidad es únicamente una migración determinista del estado legacy.

---

## 5. Integración con CI

El workflow existente ejecutará, cuando corresponda por sus triggers normales:

```bash
node scripts/verify_no_new_singletons.mjs --self-test
node scripts/verify_no_new_singletons.mjs
```

El gate corre antes de Flutter Analyze/Test para fallar rápido ante una regresión arquitectónica.

No se habilitó un workflow nuevo ni se cambió el trigger para esta rama.

---

## 6. Pruebas del detector

Antes de versionarlo se ejecutó el self-test del script exacto con Node.

Resultado:

```text
Anti-singleton self-test OK (5 casos).
```

Casos cubiertos:

1. detecta `businessId: '1'`;
2. detecta `configuracion_negocio` tomada como primera fila;
3. detecta SQL `business_id = 1`;
4. no marca el literal `'1'` usado como código DNI;
5. acepta `organization_id` dinámico.

Adicionalmente, los siete blobs baseline fueron verificados contra la rama antes de fijarlos.

La ejecución integral de Flutter/DB/Actions queda fuera de esta fase y se mantiene para la validación local posterior, conforme al flujo actual del proyecto.

---

## 7. Criterios de aceptación

- [x] detector anti-singleton implementado;
- [x] falsos positivos obvios del literal `1` evitados;
- [x] singleton explícito bloqueado;
- [x] singleton implícito «primera empresa» bloqueado;
- [x] siete archivos legacy congelados por hash;
- [x] nuevas migraciones posteriores al baseline vigiladas;
- [x] excepción de backfill explícita y auditable definida;
- [x] self-test verde;
- [x] gate incorporado al CI existente;
- [x] no se activaron Actions para esta rama;
- [x] no se modificó la base de datos en esta fase.

## Resultado

**Fase 0.3 APROBADA.**

Con Fases 0.1, 0.2 y 0.3 cerradas, el **Gate del Bloque 0 queda VERDE**.

Siguiente fase autorizada:

```text
Fase 1.1 — organizations
```
