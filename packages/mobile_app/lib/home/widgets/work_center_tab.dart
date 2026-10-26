import 'package:core_logic/core_logic.dart';
import 'work_center_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/navigation_utils.dart';
import '../../features/Cotizar/pages/lista_cotizaciones_page.dart';
import '../../features/clientes/pages/clientes_page.dart';
import '../../features/configuracion/pages/preferencias_page.dart';
import '../../features/deudas/pages/deudas_page.dart';
import '../../features/empleados/pages/gestion_empleados_page.dart';
import '../../features/facturacion/pages/documentos_electronicos_page.dart';
import '../../features/facturacion/pages/gestion_transporte_page.dart';
import '../../features/kardex/pages/kardex_page.dart';
import '../../features/proveedores/pages/gestion_proveedores_page.dart';
import '../../features/reportes/pages/reportes_page.dart';

/// Dedicated fifth workspace tab. Existing business screens are reused;
/// access to admin-only modules is not widened by this new navigation.
class WorkCenterTab extends ConsumerStatefulWidget {
  const WorkCenterTab({
    super.key,
    required this.onAdminManagement,
    this.capabilities,
  });

  final VoidCallback onAdminManagement;
  final BusinessCapabilities? capabilities;

  @override
  ConsumerState<WorkCenterTab> createState() => _WorkCenterTabState();
}

class _WorkCenterTabState extends ConsumerState<WorkCenterTab> {
  String _query = '';

  void _open(Widget page) {
    AppNavigator.navegarA(context, page);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final admin = AppRoles.isAdmin(ref.watch(rolProvider));
    final commercial = <_WorkModule>[
      const _WorkModule(
        'Cotizaciones',
        Icons.description_outlined,
        ListaCotizacionesPage(),
      ),
      const _WorkModule(
        'Clientes',
        Icons.people_outline_rounded,
        ClientesPage(),
      ),
      const _WorkModule('Deudas', Icons.credit_card_outlined, DeudasPage()),
      if (WorkCenterAccess.enabled(
        widget.capabilities,
        BusinessModule.electronicDocuments,
      ))
        const _WorkModule(
          'Documentos',
          Icons.article_outlined,
          DocumentosElectronicosPage(),
        ),
    ];
    final internal = <_WorkModule>[
      const _WorkModule(
        'Apariencia',
        Icons.palette_outlined,
        PreferenciasPage(),
        subtitle: 'Tema, color y personalización',
      ),
      const _WorkModule(
        'Transporte',
        Icons.local_shipping_outlined,
        GestionTransportePage(),
        subtitle: 'Vehículos y conductores',
      ),
      if (admin) ...const [
        _WorkModule(
          'Reportes',
          Icons.bar_chart_outlined,
          ReportesPage(),
          subtitle: 'Resultados y estadísticas',
        ),
      ],
      if (admin &&
          WorkCenterAccess.enabled(
            widget.capabilities,
            BusinessModule.inventory,
          ))
        const _WorkModule(
          'Kardex',
          Icons.receipt_long_outlined,
          KardexPage(),
          subtitle: 'Historial de inventario',
        ),
      if (admin &&
          WorkCenterAccess.enabled(
            widget.capabilities,
            BusinessModule.suppliers,
          ))
        const _WorkModule(
          'Proveedores',
          Icons.storefront_outlined,
          GestionProveedoresPage(),
          subtitle: 'Directorio de proveedores',
        ),
      if (admin)
        const _WorkModule(
          'Personal',
          Icons.badge_outlined,
          GestionEmpleadosPage(),
          subtitle: 'Gestión de personal',
        ),
    ];
    bool matches(_WorkModule item) => (item.label + ' ' + (item.subtitle ?? ''))
        .toLowerCase()
        .contains(_query.trim().toLowerCase());
    final filteredCommercial = commercial.where(matches).toList();
    final filteredInternal = internal.where(matches).toList();
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 118),
          children: [
            Text(
              'Centro de trabajo',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Todas las herramientas de tu negocio, organizadas en un solo lugar.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar módulo...',
              ),
            ),
            const SizedBox(height: 24),
            if (filteredCommercial.isNotEmpty) ...[
              _heading(context, 'Comercial'),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final tileWidth = (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final item in filteredCommercial)
                        SizedBox(
                          width: tileWidth,
                          child: _moduleTile(context, item),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
            if (filteredInternal.isNotEmpty) ...[
              _heading(context, 'Gestión interna'),
              const SizedBox(height: 12),
              for (final item in filteredInternal) ...[
                _moduleRow(context, item),
                const SizedBox(height: 10),
              ],
            ],
            if (admin && _query.isEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onAdminManagement,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('Administrar módulos del negocio'),
              ),
            ],
            if (filteredCommercial.isEmpty && filteredInternal.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 64),
                child: Center(child: Text('No se encontraron módulos')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String label) => Text(
    label,
    style: Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
  );

  BoxDecoration _decoration(BuildContext context) {
    final theme = Theme.of(context);
    return BoxDecoration(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: theme.colorScheme.outline.withValues(alpha: 0.60),
      ),
    );
  }

  Widget _moduleTile(BuildContext context, _WorkModule item) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _open(item.page),
      child: Ink(
        height: 100,
        decoration: _decoration(context),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(item.icon, size: 26),
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _moduleRow(BuildContext context, _WorkModule item) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _open(item.page),
      child: Ink(
        decoration: _decoration(context),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 5,
          ),
          leading: Icon(item.icon),
          title: Text(
            item.label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    ),
  );
}

class _WorkModule {
  const _WorkModule(this.label, this.icon, this.page, {this.subtitle});
  final String label;
  final IconData icon;
  final Widget page;
  final String? subtitle;
}
