import 'package:core_logic/core_logic.dart';
import 'package:core_logic/business/application/business_module_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/desktop_permissions_panel.dart';
import '../catalog/desktop_variants_panel.dart';
import '../customers/desktop_customers_panel.dart';
import '../facturacion/desktop_documents_panel.dart';
import '../inventory/desktop_inventory_panel.dart';
import '../inventory/desktop_products_panel.dart';
import '../metrics/desktop_metrics_panel.dart';
import '../pricing/desktop_price_rules_panel.dart';
import '../purchases/desktop_purchases_panel.dart';
import '../reports/desktop_reports_panel.dart';
import '../sales/desktop_sales_panel.dart';
import '../services/desktop_services_panel.dart';
import '../settings/desktop_business_modules_panel.dart';
import '../suppliers/desktop_suppliers_panel.dart';
import '../traceability/desktop_traceability_config_panel.dart';
import 'desktop_dashboard_panel.dart';

class DesktopHomeShell extends ConsumerStatefulWidget {
  const DesktopHomeShell({
    super.key,
    required this.offlineAuthorization,
    required this.onSignOut,
  });

  final bool offlineAuthorization;
  final Future<void> Function() onSignOut;

  @override
  ConsumerState<DesktopHomeShell> createState() => _DesktopHomeShellState();
}

class _DesktopHomeShellState extends ConsumerState<DesktopHomeShell> {
  BusinessModule _selectedModule = BusinessModule.dashboard;
  BusinessProfile? _businessProfile;
  bool _loadingProfile = true;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadBusinessProfile);
  }

  Future<void> _loadBusinessProfile() async {
    try {
      final profile = await ref
          .read(businessProfileGatewayProvider)
          .load(allowOffline: widget.offlineAuthorization);
      if (!mounted) return;
      _applyBusinessProfile(profile);
    } catch (_) {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  void _applyBusinessProfile(BusinessProfile profile) {
    if (!mounted) return;
    setState(() {
      _businessProfile = profile;
      _loadingProfile = false;
      if (!BusinessModulePolicy.isEnabled(
        profile.capabilities,
        _selectedModule,
      )) {
        _selectedModule = BusinessModule.dashboard;
      }
    });
  }

  Future<void> _handleSignOut() async {
    setState(() => _signingOut = true);
    try {
      await widget.onSignOut();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  List<DesktopNavigationItem> _visibleDestinations(String role) {
    final capabilities = _businessProfile?.capabilities;
    final isAdmin = AppRoles.isAdmin(role);
    bool enabled(BusinessModule module) => capabilities == null
        ? const {
            BusinessModule.dashboard,
            BusinessModule.sales,
            BusinessModule.catalog,
            BusinessModule.customers,
            BusinessModule.reports,
            BusinessModule.metrics,
            BusinessModule.permissions,
            BusinessModule.moduleSettings,
          }.contains(module)
        : BusinessModulePolicy.isEnabled(capabilities, module);

    return [
      const DesktopNavigationItem(
        BusinessModule.dashboard,
        Icons.dashboard_outlined,
        Icons.dashboard,
        'Inicio',
      ),
      const DesktopNavigationItem(
        BusinessModule.sales,
        Icons.point_of_sale_outlined,
        Icons.point_of_sale,
        'Ventas',
      ),
      const DesktopNavigationItem(
        BusinessModule.catalog,
        Icons.category_outlined,
        Icons.category,
        'Productos',
      ),
      if (enabled(BusinessModule.services))
        const DesktopNavigationItem(
          BusinessModule.services,
          Icons.design_services_outlined,
          Icons.design_services,
          'Servicios',
        ),
      if (enabled(BusinessModule.traceability) && isAdmin)
        const DesktopNavigationItem(
          BusinessModule.traceability,
          Icons.qr_code_2_outlined,
          Icons.qr_code_2,
          'Trazabilidad',
        ),
      if (enabled(BusinessModule.variants))
        const DesktopNavigationItem(
          BusinessModule.variants,
          Icons.account_tree_outlined,
          Icons.account_tree,
          'Variantes',
        ),
      const DesktopNavigationItem(
        BusinessModule.pricing,
        Icons.sell_outlined,
        Icons.sell,
        'Precios',
      ),
      if (enabled(BusinessModule.inventory))
        const DesktopNavigationItem(
          BusinessModule.inventory,
          Icons.inventory_outlined,
          Icons.inventory,
          'Inventario',
        ),
      const DesktopNavigationItem(
        BusinessModule.customers,
        Icons.people_outline,
        Icons.people,
        'Clientes',
      ),
      if (enabled(BusinessModule.suppliers))
        const DesktopNavigationItem(
          BusinessModule.suppliers,
          Icons.local_shipping_outlined,
          Icons.local_shipping,
          'Proveedores',
        ),
      if (enabled(BusinessModule.purchases))
        const DesktopNavigationItem(
          BusinessModule.purchases,
          Icons.shopping_cart_checkout_outlined,
          Icons.shopping_cart_checkout,
          'Compras',
        ),
      if (enabled(BusinessModule.electronicDocuments))
        const DesktopNavigationItem(
          BusinessModule.electronicDocuments,
          Icons.receipt_long_outlined,
          Icons.receipt_long,
          'Facturación',
        ),
      const DesktopNavigationItem(
        BusinessModule.reports,
        Icons.analytics_outlined,
        Icons.analytics,
        'Reportes',
      ),
      const DesktopNavigationItem(
        BusinessModule.metrics,
        Icons.speed_outlined,
        Icons.speed,
        'Métricas',
      ),
      if (isAdmin)
        const DesktopNavigationItem(
          BusinessModule.moduleSettings,
          Icons.tune_outlined,
          Icons.tune,
          'Módulos',
        ),
      if (isAdmin)
        const DesktopNavigationItem(
          BusinessModule.permissions,
          Icons.admin_panel_settings_outlined,
          Icons.admin_panel_settings,
          'Permisos',
        ),
    ];
  }

  Widget _panelFor(BusinessModule module, String role) {
    return switch (module) {
      BusinessModule.sales => const DesktopSalesPanel(key: ValueKey('sales')),
      BusinessModule.catalog => const DesktopProductsPanel(
        key: ValueKey('products'),
      ),
      BusinessModule.services => const DesktopServicesPanel(
        key: ValueKey('services'),
      ),
      BusinessModule.traceability => const DesktopTraceabilityConfigPanel(
        key: ValueKey('traceability'),
      ),
      BusinessModule.variants => const DesktopVariantsPanel(
        key: ValueKey('variants'),
      ),
      BusinessModule.pricing => const DesktopPriceRulesPanel(
        key: ValueKey('pricing'),
      ),
      BusinessModule.inventory => const DesktopInventoryPanel(
        key: ValueKey('inventory'),
      ),
      BusinessModule.customers => const DesktopCustomersPanel(
        key: ValueKey('customers'),
      ),
      BusinessModule.suppliers => const DesktopSuppliersPanel(
        key: ValueKey('suppliers'),
      ),
      BusinessModule.purchases => const DesktopPurchasesPanel(
        key: ValueKey('purchases'),
      ),
      BusinessModule.electronicDocuments => const DesktopDocumentsPanel(
        key: ValueKey('documents'),
      ),
      BusinessModule.reports => const DesktopReportsPanel(
        key: ValueKey('reports'),
      ),
      BusinessModule.metrics => const DesktopMetricsPanel(
        key: ValueKey('metrics'),
      ),
      BusinessModule.moduleSettings => DesktopBusinessModulesPanel(
        key: const ValueKey('module-settings'),
        onProfileSaved: _applyBusinessProfile,
      ),
      BusinessModule.permissions => const DesktopPermissionsPanel(
        key: ValueKey('permissions'),
      ),
      _ => DesktopDashboardPanel(
        key: const ValueKey('overview'),
        role: role,
        offlineAuthorization: widget.offlineAuthorization,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(rolProvider);
    final user = Supabase.instance.client.auth.currentUser;
    final branding = ref
        .watch(businessBrandingProvider(widget.offlineAuthorization))
        .asData
        ?.value;
    final destinations = _visibleDestinations(role);
    var selectedIndex = destinations.indexWhere(
      (destination) => destination.module == _selectedModule,
    );
    if (selectedIndex < 0) selectedIndex = 0;
    final activeModule = destinations[selectedIndex].module;

    return Scaffold(
      body: Row(
        children: [
          DesktopNavigationSidebar(
            branding: branding,
            destinations: destinations,
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedModule = destinations[index].module);
            },
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _DesktopTopBar(
                  role: role,
                  email: user?.email ?? '',
                  businessName:
                      branding?.effectiveDisplayName ??
                      BusinessBranding.fallbackDisplayName,
                  signingOut: _signingOut,
                  onSignOut: _handleSignOut,
                ),
                if (_loadingProfile)
                  const LinearProgressIndicator(minHeight: 2),
                if (widget.offlineAuthorization)
                  const MaterialBanner(
                    content: Text(
                      'Sesión restaurada con autorización local. Algunas '
                      'operaciones permanecerán deshabilitadas hasta recuperar conexión.',
                    ),
                    leading: Icon(Icons.wifi_off_outlined),
                    actions: [SizedBox.shrink()],
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _panelFor(activeModule, role),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DesktopNavigationSidebar extends StatelessWidget {
  const DesktopNavigationSidebar({
    super.key,
    required this.branding,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final BusinessBranding? branding;
  final List<DesktopNavigationItem> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
              child: SizedBox(
                width: 210,
                child: Row(
                  children: [
                    _DesktopTenantBrandLogo(branding: branding),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        branding?.effectiveDisplayName ??
                            BusinessBranding.fallbackDisplayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: destinations.length,
                itemBuilder: (context, index) {
                  final destination = destinations[index];
                  final selected = index == selectedIndex;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: ListTile(
                      key: ValueKey(
                        'desktop-nav-${destination.module.name}-$index',
                      ),
                      selected: selected,
                      leading: Icon(
                        selected
                            ? destination.selectedIcon
                            : destination.icon,
                      ),
                      title: Text(destination.label),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onTap: () => onDestinationSelected(index),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopTenantBrandLogo extends StatelessWidget {
  const _DesktopTenantBrandLogo({required this.branding});

  final BusinessBranding? branding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.storefront_outlined, color: colors.onPrimaryContainer),
    );
    final uri = branding?.logoUri;
    if (uri == null) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 42,
        height: 42,
        color: colors.surfaceContainerHighest,
        child: Image.network(
          uri.toString(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

class DesktopNavigationItem {
  const DesktopNavigationItem(
    this.module,
    this.icon,
    this.selectedIcon,
    this.label,
  );

  final BusinessModule module;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({
    required this.role,
    required this.email,
    required this.businessName,
    required this.signingOut,
    required this.onSignOut,
  });

  final String role;
  final String email;
  final String businessName;
  final bool signingOut;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Expanded(
              child: Text(
                businessName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 20),
            if (email.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(email),
              ),
            Chip(label: Text(role == 'sin_rol' ? 'Sin rol' : role)),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Cerrar sesión',
              onPressed: signingOut ? null : onSignOut,
              icon: signingOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout),
            ),
          ],
        ),
      ),
    );
  }
}
