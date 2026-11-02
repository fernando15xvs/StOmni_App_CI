# Roadmap móvil — Inicio, Balance, Inventario, Reportes y Gestión SUNAT

## 1. Objetivo

Reorganizar la experiencia móvil de StOmni SaaS para que cada pantalla tenga una responsabilidad clara, se eliminen duplicaciones y la navegación entre resumen, operación diaria, análisis histórico y gestión tributaria sea coherente.

Este roadmap no pretende rehacer la lógica de negocio existente. La prioridad es reorganizar la experiencia móvil reutilizando contratos, permisos y servicios actuales, y ampliar backend únicamente donde sea necesario para obtener agregados históricos correctos y escalables.

## 2. Responsabilidad final de cada área

- **Inicio:** panorama del negocio, tendencias y alertas que requieren atención.
- **Balance:** operación financiera del día actual.
- **Inventario:** estado actual del catálogo y existencias.
- **Reportes:** análisis histórico por período.
- **Gestión SUNAT:** operación y resolución de documentos electrónicos.
- **Centro de trabajo:** acceso a módulos especializados, incluyendo Reportes y Gestión SUNAT.

### Reglas de producto y diseño

1. No duplicar en Inicio datos operativos que ya pertenecen a Balance.
2. No usar Reportes para ejecutar acciones tributarias.
3. No usar Gestión SUNAT como motor de estadísticas históricas.
4. No contabilizar Guías de Remisión Electrónica como ventas o facturación monetaria.
5. Evitar cards contenedoras con otras cards cuando una jerarquía plana sea suficiente.
6. Mantener compatibilidad con modo claro, oscuro y color principal configurable.
7. Mantener permisos, capacidades y aislamiento multi-tenant existentes.
8. Todo cambio se implementa primero en el repositorio privado fuente de verdad y se valida posteriormente mediante el espejo CI.

## 3. Estado actual verificado

### Balance

Balance está limitado explícitamente al día actual mediante `AppTime.startOfToday()` y `AppTime.endOfToday()`.

Actualmente muestra ingresos, egresos, balance/neto, descuentos y movimientos del día, además del acceso al detalle de venta, gasto o pago. El CTA `Ver detalle` abre actualmente `ReportesPage`.

Por tanto, Balance seguirá siendo una pantalla operativa diaria y no se convertirá en histórico.

### Reportes

Actualmente dispone de dos pestañas: **Financiero** e **Inventario**. Soporta períodos Diario, Semanal, Mensual, Anual y Personalizado. Reportes es la pantalla apropiada para análisis histórico.

### Documentos electrónicos

La pantalla actual es operativa. Permite listar Facturas, Boletas, Notas y Guías; filtrar y buscar; consultar estado SUNAT; reintentar envíos; abrir documentos; crear GRE; y gestionar bajas, anulaciones y procesos tributarios.

Esta funcionalidad no debe desaparecer dentro de Reportes. Se renombrará y enfocará como **Gestión SUNAT**.

# 4. Fase 1 — Reestructuración de Inicio

## 4.1 Eliminar duplicaciones

Retirar de Inicio:

- cantidad total de productos registrados;
- cards de Ventas de hoy;
- cards de Egresos de hoy;
- Flujo neto como métrica independiente;
- actividad reciente de ventas/egresos que duplique Balance;
- la card contenedora grande que agrupa otras cards cuando no agrega jerarquía útil.

Balance ya cubre la actividad financiera diaria.

## 4.2 Nueva sección Rendimiento

Crear una sección visual plana con selector principal:

- Ventas
- Egresos
- Facturación

Selector temporal:

- 7 días
- 30 días
- Mes
- Año

Se mostrará un único gráfico que cambia según la selección.

### Ventas

Mostrar tendencia histórica de ventas.

### Egresos

Recuperar el gráfico histórico de egresos que existía anteriormente.

### Facturación

Mostrar evolución de facturación electrónica, separando principalmente Boletas y Facturas. No incluir GRE dentro del importe facturado.

## 4.3 CTA de Inicio

El CTA recomendado será **Analizar período**.

Comportamiento:

- Ventas + período -> Reportes > Financiero > Ingresos + mismo período.
- Egresos + período -> Reportes > Financiero > Egresos + mismo período.
- Facturación + período -> Reportes > Facturación + mismo período.

## 4.4 Alertas

Renombrar `Estado actual y alertas` a **Alertas**.

Mostrar únicamente situaciones accionables, por ejemplo:

- productos con stock bajo;
- productos agotados;
- cuentas vencidas por cobrar;
- pagos próximos o vencidos;
- comprobantes SUNAT rechazados;
- documentos pendientes de envío.

Cada alerta deberá navegar al módulo que permite resolverla.

Si no existen alertas: **Todo en orden — No tienes alertas pendientes.**

## 4.5 Criterios de aceptación

- Inicio no duplica Ventas/Egresos/Neto de hoy.
- Inicio no muestra el total de productos registrados.
- Existe un único gráfico de Rendimiento.
- Ventas, Egresos y Facturación comparten la misma zona visual.
- El período seleccionado se conserva al navegar a Reportes.
- Alertas contiene únicamente elementos accionables.
- No existen cards decorativas anidadas innecesariamente.

# 5. Fase 2 — Ajuste menor de Balance

Balance conserva su responsabilidad actual: **qué ocurrió hoy con el dinero**.

## 5.1 Mantener

- ingresos de hoy;
- egresos de hoy;
- balance neto del día;
- descuentos;
- movimientos;
- acceso al detalle de cada operación;
- caja chica y sincronización actual.

## 5.2 Cambiar CTA

Cambiar el actual `Ver detalle` por **Histórico financiero**.

Debe abrir directamente `Reportes > Financiero`.

## 5.3 Criterios de aceptación

- Balance continúa limitado al día actual.
- No se agregan gráficos históricos a Balance.
- Histórico financiero abre Reportes > Financiero.
- No se duplica el selector de Rendimiento de Inicio.

# 6. Fase 3 — Ajuste menor de Inventario

Mover el contador de productos registrados desde Inicio hacia Inventario.

## 6.1 Resumen superior

Agregar un resumen compacto, sin una gran card contenedora:

- Productos
- Stock bajo
- Sin stock

Ejemplo conceptual: `428 productos · 17 stock bajo · 3 sin stock`.

## 6.2 Indicadores interactivos

- tocar Productos -> mostrar todos;
- tocar Stock bajo -> aplicar filtro de stock bajo;
- tocar Sin stock -> aplicar filtro de agotados.

## 6.3 Criterios de aceptación

- El total de productos ya no aparece en Inicio.
- Inventario muestra total de productos, stock bajo y agotados.
- Los indicadores aplican filtros reales.
- No se altera el flujo actual de creación, edición o consulta de productos.

# 7. Fase 4 — Reorganización de Reportes

Convertir Reportes en el centro de análisis histórico.

Nueva estructura: **Financiero | Inventario | Facturación**.

## 7.1 Filtros globales

Mantener Diario, Semanal, Mensual, Anual y Personalizado.

Reportes deberá poder recibir contexto inicial desde otras pantallas:

- pestaña;
- período;
- fecha/rango;
- tipo financiero;
- tipo de documento o estado cuando corresponda.

## 7.2 Reportes > Financiero

Mantener y mejorar:

- Ingresos;
- Egresos;
- Flujo neto;
- Descuentos;
- movimientos del período;
- distribución por método de pago;
- exportación.

### Flujo neto

Se mantiene únicamente como indicador histórico: `Ingresos - Egresos = Flujo neto`. No se presentará como utilidad o ganancia contable.

## 7.3 Reportes > Inventario

Mantener entradas, salidas, traslados, filtros por producto, histórico de movimientos y exportaciones actuales.

## 7.4 Criterios de aceptación

- Reportes tiene tres pestañas.
- Puede abrir en una pestaña, filtro y período específicos.
- Los filtros globales son consistentes entre las tres pestañas.
- El contexto recibido desde Inicio o Balance se respeta al abrir.

# 8. Fase 5 — Nueva sección Reportes > Facturación

Esta sección será exclusivamente analítica.

## 8.1 KPIs por período

Mostrar:

- total facturado;
- total por Facturas;
- total por Boletas;
- Notas de crédito;
- Notas de débito;
- cantidad total de documentos;
- aceptados;
- pendientes;
- rechazados;
- anulados;
- cantidad de GRE emitidas.

## 8.2 Reglas monetarias

- Facturas y Boletas forman parte del importe facturado.
- Notas de crédito reducen el importe cuando corresponda.
- Notas de débito incrementan el importe cuando corresponda.
- GRE no suma importe de venta.

## 8.3 Gráficos

Gráfico principal: **Facturación por período**.

Series principales:

- Boletas
- Facturas

Resumen complementario:

- porcentaje Boletas vs Facturas;
- evolución temporal;
- documentos por estado.

## 8.4 Drill-down

- tocar `3 rechazados` -> Gestión SUNAT filtrada por rechazados y mismo período;
- tocar `58 Facturas` -> Gestión SUNAT filtrada por Facturas y mismo período;
- tocar `17 Guías` -> Gestión SUNAT filtrada por GRE y mismo período.

## 8.5 Criterios de aceptación

- No se usan resultados paginados de Gestión SUNAT para calcular KPIs.
- Las estadísticas son completas para todo el período.
- GRE no afecta el total facturado.
- Los estados tributarios son navegables hacia Gestión SUNAT.

# 9. Fase 6 — Backend agregado para facturación

La lista actual de documentos trabaja con paginación de 50 elementos. No se usará para sumar estadísticas.

Crear un contrato agregado server-side por organización y período que devuelva como mínimo:

- totales monetarios por tipo;
- cantidad por tipo;
- cantidad por estado;
- serie temporal agregada;
- notas de crédito/débito;
- cantidad de GRE.

## 9.1 Requisitos

- tenant actual derivado del contexto autenticado;
- sin posibilidad de consultar otra organización;
- permisos/capabilities respetados;
- rangos validados;
- no exponer payload tributario sensible innecesario;
- respuesta adecuada para gráficos sin descargar miles de documentos.

## 9.2 Pruebas

Agregar pruebas de aislamiento multi-tenant, períodos, estados, notas de crédito, notas de débito, GRE excluidas del total monetario, documentos anulados según política definida y datasets vacíos.

# 10. Fase 7 — Renombrar Documentos electrónicos a Gestión SUNAT

En Centro de trabajo, **Documentos** pasa a **Gestión SUNAT**.

Subtítulo recomendado: `Comprobantes, envíos, consultas y bajas`.

La pantalla mantiene su función operativa.

## 10.1 Mantener

- Facturas;
- Boletas;
- Notas;
- Guías;
- búsqueda;
- filtros;
- consulta de estado SUNAT;
- reintento de envío;
- detalle del documento;
- creación de GRE;
- anulaciones/bajas;
- procesos tributarios.

## 10.2 No convertir en reporte

Gestión SUNAT no calculará total facturado histórico, evolución por período, porcentaje Boletas/Facturas ni KPIs agregados. Eso pertenece a Reportes > Facturación.

# 11. Fase 8 — Mejorar UX de Gestión SUNAT

## 11.1 Filtros operativos

Prioridad por estado:

- Todos
- Pendientes
- Rechazados
- Aceptados

Tipo:

- Facturas
- Boletas
- Notas
- Guías

Mantener búsqueda por número, cliente y estado.

## 11.2 Jerarquía visual

Los documentos problemáticos deben destacar más que los aceptados. Un documento rechazado debe mostrar claramente el motivo y la acción de reintento; un documento aceptado puede mostrarse de forma más discreta.

## 11.3 Acceso a análisis

Agregar **Ver reporte de facturación**, que abre `Reportes > Facturación` con el período actual cuando aplique.

# 12. Fase 9 — Navegación cruzada

## Inicio -> Reportes

- Ventas -> Financiero / Ingresos
- Egresos -> Financiero / Egresos
- Facturación -> Facturación

## Balance -> Reportes

- Histórico financiero -> Financiero

## Reportes -> Gestión SUNAT

- Facturas -> Gestión SUNAT / Facturas
- Boletas -> Gestión SUNAT / Boletas
- Rechazados -> Gestión SUNAT / Rechazados
- Pendientes -> Gestión SUNAT / Pendientes
- GRE -> Gestión SUNAT / Guías

## Gestión SUNAT -> Reportes

- Ver reporte de facturación -> Reportes / Facturación

Toda navegación debe preservar el período cuando sea semánticamente válido.

# 13. Fase 10 — Unificación visual móvil

Aplicar a Inicio, Balance, Inventario, Reportes y Gestión SUNAT:

- eliminar gradientes decorativos de títulos;
- reducir cards anidadas;
- usar superficies planas;
- unificar tipografía;
- unificar radios y espaciado;
- respetar color principal configurable;
- soportar claro/oscuro;
- mantener colores semánticos únicamente cuando aporten significado;
- conservar formularios y lógica operativa.

No se realizará una refactorización visual de escritorio dentro de este bloque.

# 14. Fase 11 — Pruebas y gates

## Inicio

- no duplica Balance;
- Productos registrados no vuelve a Inicio;
- Alertas solo muestra elementos relevantes;
- Rendimiento conserva filtros y navegación.

## Balance

- sigue usando el día actual;
- Histórico financiero abre Reportes correctamente.

## Inventario

- muestra total/stock bajo/sin stock;
- los contadores filtran correctamente.

## Reportes

- tres pestañas presentes;
- parámetros iniciales funcionan;
- períodos correctos;
- Flujo neto correcto;
- navegación a Gestión SUNAT correcta.

## Facturación

- totales completos;
- Facturas/Boletas correctas;
- NC/ND correctas;
- GRE excluidas del monto;
- estados tributarios correctos;
- aislamiento multi-tenant.

## Gestión SUNAT

- consultar;
- reintentar;
- crear GRE;
- procesos tributarios;
- filtros por estado/tipo;
- navegación hacia Reportes.

# 15. Orden de implementación recomendado

1. Crear contratos de navegación hacia Reportes.
2. Reestructurar Reportes para aceptar pestaña/período/filtros iniciales.
3. Añadir Reportes > Facturación.
4. Crear backend agregado de facturación + pruebas de seguridad.
5. Renombrar Documentos -> Gestión SUNAT.
6. Mejorar filtros y navegación de Gestión SUNAT.
7. Reestructurar Inicio.
8. Ajustar CTA de Balance.
9. Mover indicadores de productos a Inventario.
10. Conectar alertas de Inicio.
11. Ejecutar pasada visual conjunta sobre las cinco pantallas.
12. Ejecutar pruebas, formato, análisis y gates.
13. Sincronizar mirror CI.
14. Requerir validación completa 7/7.
15. Generar nueva build QA solo después de CI verde.

Este orden evita construir Inicio sobre contratos todavía inestables.

# 16. Fuera de alcance

- rediseño completo de escritorio;
- cambios generales de core business no relacionados;
- cambios de precios/suscripciones;
- despliegue a producción;
- reemplazo de la lógica tributaria existente;
- eliminación de Gestión SUNAT;
- uso de GRE como ingreso financiero.

# 17. Definición de terminado

El bloque se considera cerrado únicamente cuando:

- Inicio, Balance, Inventario, Reportes y Gestión SUNAT cumplen las responsabilidades definidas;
- no existen duplicaciones relevantes entre Inicio y Balance;
- Reportes centraliza el histórico;
- Gestión SUNAT conserva las acciones operativas;
- Facturación dispone de agregados server-side completos y tenant-safe;
- la experiencia claro/oscuro es consistente;
- pruebas nuevas y existentes pasan;
- el mirror corresponde al source privado;
- CI público termina 7/7 verde;
- la build QA posterior se genera desde el SHA privado validado.
