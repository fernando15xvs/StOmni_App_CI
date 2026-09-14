import 'package:core_logic/core_logic.dart';
import 'package:core_logic/business/application/business_module_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/almacen/pages/almacen_page.dart';
import '../features/almacen/pages/mover_stock_page.dart';
import '../features/balance/pages/balance_page.dart';
import '../features/compras/pages/compras_page.dart';
import '../features/configuracion/pages/modulos_negocio_page.dart';
import '../features/metricas/pages/metricas_configurables_page.dart';
import '../features/precios/pages/precios_promociones_page.dart';
import '../features/servicios/pages/servicios_page.dart';
import '../features/trazabilidad/pages/trazabilidad_config_page.dart';
import '../features/variantes/pages/variantes_page.dart';
import 'controllers/home_controller.dart';
import 'home_notifier.dart';
import 'widgets/custom_bottom_nav.dart';
import 'widgets/dashboard_tab.dart';
import 'widgets/dynamic_home_fab.dart';

class HomePage extends ConsumerStatefulWidget {
  final int pestanaInicial;

  const HomePage({super.key, this.pestanaInicial = 0});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late List<bool> _paginasVisitadas;
  late final VoidCallback _legacyRefreshBridgeCallback;
  BusinessProfile? _businessProfile;
  bool _isFabVisible = true;
  final ValueNotifier<double?> _dragNotifier = ValueNotifier<double?>(null);

  final List<Widget> _pestanas = [
    const DashboardTab(),
    const BalancePage(),
    const AlmacenPage(),
    const MoverStockPage(),
  ];

  @override
  void initState() {
    super.initState();
    _legacyRefreshBridgeCallback = () {
      ref.read(homeRefreshRevisionProvider.notifier).state++;
    };
    homeRefreshNotifier.attach(_legacyRefreshBridgeCallback);

    Future.microtask(() async {
      ref.read(homeTabProvider.notifier).state = widget.pestanaInicial;
      await _loadBusinessProfile();
    });
    _paginasVisitadas = List.generate(
      4,
      (index) => index == widget.pestanaInicial,
    );
  }

  @override
  void dispose() {
    homeRefreshNotifier.detach(_legacyRefreshBridgeCallback);
    _dragNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadBusinessProfile() async {
    try {
      final profile = await ref.read(businessProfileGatewayProvider).load();
      if (!mounted) return;
      setState(() => _businessProfile = profile);
      final current = ref.read(homeTabProvider);
      if (!profile.capabilities.inventoryEnabled && current >= 2) {
        ref.read(homeTabProvider.notifier).state = 0;
      }
    } catch (_) {
      // Fail-closed: hasta cargar capacidades, la UI oculta módulos opcionales.
    }
  }

  Future<void> _showAdminManagement() async {
    final capabilities = _businessProfile?.capabilities;
    bool enabled(BusinessModule module) => capabilities != null &&
        BusinessModulePolicy.isEnabled(capabilities, module);

    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: const Text('Módulos del negocio'),
              subtitle: const Text('Activar o desactivar capacidades'),
              onTap: () => Navigator.pop(context, 'modules'),
            ),
            if (enabled(BusinessModule.purchases))
              ListTile(
                leading: const Icon(Icons.shopping_cart_checkout),
                title: const Text('Compras'),
                subtitle: const Text('Órdenes de proveedor y recepciones'),
                onTap: () => Navigator.pop(context, 'purchases'),
              ),
            if (enabled(BusinessModule.variants))
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('Variantes'),
                subtitle: const Text('Agrupar productos por atributos'),
                onTap: () => Navigator.pop(context, 'variants'),
              ),
            if (enabled(BusinessModule.services))
              ListTile(
                leading: const Icon(Icons.design_services_outlined),
                title: const Text('Servicios'),
                subtitle: const Text('Ítems comerciales sin inventario'),
                onTap: () => Navigator.pop(context, 'services'),
              ),
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: const Text('Precios y promociones'),
              subtitle: const Text('Reglas por producto, presentación y cantidad'),
              onTap: () => Navigator.pop(context, 'pricing'),
            ),
            if (enabled(BusinessModule.traceability))
              ListTile(
                leading: const Icon(Icons.qr_code_2_outlined),
                title: const Text('Trazabilidad'),
                subtitle: const Text('Preconfigurar lote, vencimiento o serie'),
                onTap: () => Navigator.pop(context, 'traceability'),
              ),
            ListTile(
              leading: const Icon(Icons.speed_outlined),
              title: const Text('Métricas'),
              subtitle: const Text('KPIs configurables del negocio'),
              onTap: () => Navigator.pop(context, 'metrics'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || destination == null) return;
    final page = switch (destination) {
      'modules' => const ModulosNegocioPage(),
      'purchases' => const ComprasPage(),
      'variants' => const VariantesPage(),
      'services' => const ServiciosPage(),
      'pricing' => const PreciosPromocionesPage(),
      'traceability' => const TrazabilidadConfigPage(),
      'metrics' => const MetricasConfigurablesPage(),
      _ => null,
    };
    if (page != null) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      if (destination == 'modules') await _loadBusinessProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(homeTabProvider);
    final isAdmin = AppRoles.isAdmin(ref.watch(rolProvider));
    final inventoryEnabled = _businessProfile?.capabilities.inventoryEnabled == true;
    if (currentIndex >= 0 && currentIndex < _paginasVisitadas.length) {
      _paginasVisitadas[currentIndex] = true;
    }

    Widget? fab;
    if (currentIndex == 0 && isAdmin) {
      fab = FloatingActionButton.extended(
        heroTag: 'home_management',
        onPressed: _showAdminManagement,
        icon: const Icon(Icons.admin_panel_settings_outlined),
        label: const Text('Gestión'),
      );
    } else if (currentIndex != 0 && currentIndex != 3) {
      fab = Padding(
        key: ValueKey('fab_$currentIndex'),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            offset: _isFabVisible ? Offset.zero : const Offset(0, 2.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              opacity: _isFabVisible ? 1.0 : 0.0,
              child: const DynamicHomeFab(),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBody: true,
      body: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction == ScrollDirection.forward) {
            if (!_isFabVisible) setState(() => _isFabVisible = true);
          } else if (notification.direction == ScrollDirection.reverse) {
            if (_isFabVisible) setState(() => _isFabVisible = false);
          }
          return false;
        },
        child: IndexedStack(
          index: currentIndex.clamp(0, _pestanas.length - 1).toInt(),
          children: List.generate(4, (index) {
            return _paginasVisitadas[index]
                ? _pestanas[index]
                : const SizedBox.shrink();
          }),
        ),
      ),
      bottomNavigationBar: CustomBottomNav(
        dragNotifier: _dragNotifier,
        inventoryEnabled: inventoryEnabled,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: fab,
    );
  }
}