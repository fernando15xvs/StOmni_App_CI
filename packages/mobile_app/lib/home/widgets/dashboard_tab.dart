import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/utils/navigation_utils.dart';
import '../../core/theme/app_colors.dart';

import '../../features/almacen/pages/config_almacenes_page.dart';
import '../../features/deudas/pages/deudas_page.dart';
import '../../features/proveedores/pages/gestion_proveedores_page.dart';
import '../../features/empleados/pages/gestion_empleados_page.dart';
import '../../features/clientes/pages/clientes_page.dart';
import '../../features/Cotizar/pages/lista_cotizaciones_page.dart';
import '../../features/configuracion/pages/configuracion_negocio_page.dart';
import '../../features/configuracion/pages/preferencias_page.dart';
import '../../features/reportes/pages/reportes_page.dart';
import '../../features/kardex/pages/kardex_page.dart';
import '../../features/kardex/providers/kardex_provider.dart';
import '../../features/empleados/pages/perfil_page.dart';
import '../../features/facturacion/pages/documentos_electronicos_page.dart';
import '../../features/facturacion/pages/gestion_transporte_page.dart';
import 'package:core_logic/core_logic.dart';
import '../controllers/grafico_tendencia_provider.dart';
import '../controllers/home_controller.dart';

import 'dashboard/dashboard_metric_card.dart';
import 'dashboard/dashboard_modules.dart';
import 'dashboard/dashboard_alerts.dart';
import 'dashboard/dashboard_charts.dart';

// ==========================================================
// PESTAÑA INICIO (DASHBOARD)
// ==========================================================
class DashboardTab extends ConsumerStatefulWidget {
  const DashboardTab({super.key});

  @override
  ConsumerState<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends ConsumerState<DashboardTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Color get colorPrincipal => Theme.of(context).colorScheme.primary;
  Color get colorTextoOscuro =>
      Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1E293B);

  String _nombreUsuario = "Usuario";
  double _ventasHoy = 0.0;
  double _gastosHoy = 0.0;
  int _totalProductos = 0;
  int _lowStockCount = 0;
  double _deudasPorCobrar = 0.0;
  double _deudasPorPagar = 0.0;
  int _outOfStockCount = 0;
  bool _cargando = true;
  bool _resumenDisponible = true;

  int _diasFiltroGrafico = 7;
  int _diasFiltroGraficoEgresos = 7;

  @override
  void initState() {
    super.initState();
    _obtenerUsuario();
    _cargarTodosLosDatos();

    // Solo el administrador puede cargar datos del Kardex.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(rolProvider) == 'admin') {
        ref.read(kardexProvider.notifier).cargarKardex(silent: true);
      }
    });
  }

  Future<void> _obtenerUsuario() async {
    final nombre = await ref
        .read(dashboardRepositoryProvider)
        .obtenerNombreUsuarioActual();
    if (mounted) {
      setState(() {
        _nombreUsuario = nombre;
      });
    }
  }

  Future<void> _cargarTodosLosDatos({bool isSilent = false}) async {
    if (!mounted) return;
    if (!isSilent) setState(() => _cargando = true);
    try {
      await _cargarResumen();
      try {
        ref.invalidate(
          graficoTendenciaProvider(
            TendenciaRequest('ingreso', _diasFiltroGrafico),
          ),
        );
        ref.invalidate(
          graficoTendenciaProvider(
            TendenciaRequest('egreso', _diasFiltroGraficoEgresos),
          ),
        );
      } catch (e) {
        debugPrint("Error invalidando provider: $e");
      }
    } finally {
      if (mounted) {
        if (!isSilent) {
          setState(() => _cargando = false);
        } else {
          setState(() {});
        }
      }
    }
  }

  Future<void> _cargarResumen() async {
    try {
      final now = AppTime.now();
      final inicio = DateTime(now.year, now.month, now.day);
      final finExclusivo = inicio.add(const Duration(days: 1));

      final res = await ref
          .read(dashboardRepositoryProvider)
          .obtenerResumen(
            inicioIso: AppTime.toIsoLima(inicio),
            finIso: AppTime.toIsoLima(finExclusivo),
          );

      if (mounted) {
        setState(() {
          _resumenDisponible = true;
          _ventasHoy = (res['ventas_hoy'] as num?)?.toDouble() ?? 0.0;
          _gastosHoy = (res['gastos_hoy'] as num?)?.toDouble() ?? 0.0;
          _totalProductos = (res['total_productos'] as num?)?.toInt() ?? 0;
          _lowStockCount = (res['low_stock_count'] as num?)?.toInt() ?? 0;
          _outOfStockCount = (res['out_of_stock_count'] as num?)?.toInt() ?? 0;
          _deudasPorCobrar =
              (res['deudas_por_cobrar'] as num?)?.toDouble() ?? 0.0;
          _deudasPorPagar =
              (res['deudas_por_pagar'] as num?)?.toDouble() ?? 0.0;
        });
      }
    } catch (e) {
      debugPrint("Error en _cargarResumen: $e");
      if (mounted) {
        setState(() {
          _resumenDisponible = false;
          _ventasHoy = 0.0;
          _gastosHoy = 0.0;
          _totalProductos = 0;
          _lowStockCount = 0;
          _outOfStockCount = 0;
          _deudasPorCobrar = 0.0;
          _deudasPorPagar = 0.0;
        });
      }
    }
  }

  void _navTo(Widget page) {
    AppNavigator.navegarA(context, page).then((_) {
      if (!mounted) return;
      final allowOffline =
          ref.read(authControllerProvider).sessionStatus ==
          SessionValidationStatus.offline;
      ref.invalidate(businessBrandingProvider(allowOffline));
      _cargarTodosLosDatos(isSilent: true);
    });
  }

  void _mostrarMenuAcciones(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          padding: const EdgeInsets.only(
            top: 30,
            left: 24,
            right: 24,
            bottom: 40,
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 45,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Módulos de Trabajo",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: colorTextoOscuro,
                ),
              ),
              const SizedBox(height: 24),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    DashboardModuloItem(
                      icon: Icons.request_quote_rounded,
                      color: AppColors.cotizar,
                      titulo: "Cotizar",
                      subtitulo: "Crear y gestionar cotizaciones",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const ListaCotizacionesPage());
                      },
                    ),
                    DashboardModuloItem(
                      icon: Icons.people_alt_rounded,
                      color: AppColors.clientes,
                      titulo: "Clientes",
                      subtitulo: "Directorio de clientes",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const ClientesPage());
                      },
                    ),
                    DashboardModuloItem(
                      icon: Icons.credit_score_rounded,
                      color: AppColors.deudas,
                      titulo: "Deudas",
                      subtitulo: "Cuentas por cobrar y pagar",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const DeudasPage());
                      },
                    ),
                    DashboardModuloItem(
                      icon: Icons.document_scanner_rounded,
                      color: Colors.deepPurple,
                      titulo: "Documentos electrónicos",
                      subtitulo: "Guías, facturas, boletas y notas",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const DocumentosElectronicosPage());
                      },
                    ),
                    DashboardModuloItem(
                      icon: Icons.settings_rounded,
                      color: Colors.blueGrey,
                      titulo: "Configuración Local",
                      subtitulo: "Tema y inicio",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const PreferenciasPage());
                      },
                    ),
                    DashboardModuloItem(
                      icon: Icons.directions_bus_filled_rounded,
                      color: const Color(0xFF6A1B9A),
                      titulo: "Transporte",
                      subtitulo: "Gestión de vehículos y conductores",
                      onTap: () {
                        Navigator.pop(ctx);
                        _navTo(const GestionTransportePage());
                      },
                    ),
                    if (ref.read(rolProvider) == 'admin') ...[
                      DashboardModuloItem(
                        icon: Icons.bar_chart_rounded,
                        color: AppColors.reportes,
                        titulo: "Reportes",
                        subtitulo: "Análisis y estadísticas del negocio",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const ReportesPage());
                        },
                      ),
                      DashboardModuloItem(
                        icon: Icons.history_edu_rounded,
                        color: AppColors.kardex,
                        titulo: "Kardex",
                        subtitulo: "Movimientos e historial de inventario",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const KardexPage());
                        },
                      ),
                      DashboardModuloItem(
                        icon: Icons.local_shipping_rounded,
                        color: AppColors.proveedores,
                        titulo: "Proveedores",
                        subtitulo: "Directorio de proveedores",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const GestionProveedoresPage());
                        },
                      ),
                      DashboardModuloItem(
                        icon: Icons.badge_rounded,
                        color: AppColors.personal,
                        titulo: "Personal",
                        subtitulo: "Empleados y gestión de usuarios",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const GestionEmpleadosPage());
                        },
                      ),
                      DashboardModuloItem(
                        icon: Icons.storefront_rounded,
                        color: AppColors.almacenes,
                        titulo: "Sucursales",
                        subtitulo: "Gestión de sucursales",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const ConfigAlmacenesPage());
                        },
                      ),
                      DashboardModuloItem(
                        icon: Icons.settings_applications_rounded,
                        color: AppColors.empresa,
                        titulo: "Empresa",
                        subtitulo: "Configuración de la empresa",
                        onTap: () {
                          Navigator.pop(ctx);
                          _navTo(const ConfiguracionNegocioPage());
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final allowOffline = ref.watch(
      authControllerProvider.select(
        (state) => state.sessionStatus == SessionValidationStatus.offline,
      ),
    );
    final branding = ref
        .watch(businessBrandingProvider(allowOffline))
        .asData
        ?.value;
    ref.listen<int>(homeRefreshRevisionProvider, (previous, next) {
      if (previous != null && previous != next) {
        _cargarTodosLosDatos(isSilent: true);
      }
    });
    return _cargando
        ? _buildShimmerLoading()
        : _buildDashboardContent(branding);
  }

  Widget _buildDashboardContent(BusinessBranding? branding) {
    final hora = AppTime.now().hour;
    String saludoCompleto = hora < 12
        ? 'Buenos días'
        : (hora < 19 ? 'Buenas tardes' : 'Buenas noches');
    final anchoPantalla = MediaQuery.of(context).size.width;
    final esCelular = anchoPantalla < 600;

    final TextStyle estiloTituloSeccion = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w800,
      color: colorTextoOscuro,
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  height: 160,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.black, colorPrincipal],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(35),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 60, left: 24, right: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _TenantBrandLogo(branding: branding, size: 32),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    branding?.effectiveDisplayName ??
                                        BusinessBranding.fallbackDisplayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.88,
                                      ),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            Text(
                              "$saludoCompleto,",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _nombreUsuario,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Row(
                        children: [
                          InkWell(
                            onTap: () => _mostrarMenuAcciones(context),
                            borderRadius: BorderRadius.circular(30),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.grid_view_rounded,
                                size: 24,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () => _navTo(const PerfilPage()),
                            borderRadius: BorderRadius.circular(30),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const CircleAvatar(
                                radius: 22,
                                backgroundColor: Colors.white,
                                child: Icon(
                                  Icons.person_rounded,
                                  size: 28,
                                  color: Color(0xFF1B3A6F),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  DashboardCharts(
                    titulo: "Tendencia de ingresos",
                    diasFiltro: _diasFiltroGrafico,
                    isEgreso: false,
                    colorPrincipal: colorPrincipal,
                    onFiltroChanged: (val) {
                      setState(() => _diasFiltroGrafico = val);
                    },
                  ),
                  const SizedBox(height: 20),
                  DashboardCharts(
                    titulo: "Tendencia de egresos",
                    diasFiltro: _diasFiltroGraficoEgresos,
                    isEgreso: true,
                    colorPrincipal: colorPrincipal,
                    onFiltroChanged: (val) {
                      setState(() => _diasFiltroGraficoEgresos = val);
                    },
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 20,
                right: 20,
                top: 10,
                bottom: 20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 16),
                    child: Text(
                      "Estado actual y alertas",
                      style: estiloTituloSeccion,
                    ),
                  ),
                  _buildMetricasRapidas(esCelular),
                  const SizedBox(height: 16),
                  DashboardAlerts(
                    cargando: _cargando,
                    resumenDisponible: _resumenDisponible,
                    deudasPorPagar: _deudasPorPagar,
                    lowStockCount: _lowStockCount,
                    outOfStockCount: _outOfStockCount,
                    deudasPorCobrar: _deudasPorCobrar,
                    onNavigate: _navTo,
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 130)),
        ],
      ),
    );
  }

  Widget _buildMetricasRapidas(bool esCelular) {
    String margenStr = _resumenDisponible ? "0%" : "—";
    if (_resumenDisponible && _ventasHoy > 0) {
      double margen = ((_ventasHoy - _gastosHoy) / _ventasHoy) * 100;
      margenStr = "${margen.toStringAsFixed(0)}%";
    }

    final children = [
      Expanded(
        child: DashboardMetricCard(
          titulo: "Productos",
          valor: _resumenDisponible ? "$_totalProductos" : "—",
          icon: Icons.inventory_2_rounded,
          color: Colors.blue.shade600,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: DashboardMetricCard(
          titulo: "Flujo neto",
          valor: margenStr,
          icon: Icons.trending_up_rounded,
          color: Colors.amber.shade600,
        ),
      ),
    ];

    return Row(children: children);
  }

  Widget _buildShimmerLoading() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Shimmer.fromColors(
        baseColor: isDark ? Colors.grey[800]! : Colors.grey.shade300,
        highlightColor: isDark ? Colors.grey[700]! : Colors.grey.shade100,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 40),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(width: 100, height: 16, color: Colors.white),
                      const SizedBox(height: 8),
                      Container(width: 140, height: 24, color: Colors.white),
                    ],
                  ),
                  Container(
                    width: 45,
                    height: 45,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 35),
              Container(
                width: double.infinity,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 25),
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 25),
              Row(
                children: List.generate(
                  4,
                  (i) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Container(
                        height: 70,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TenantBrandLogo extends StatelessWidget {
  const _TenantBrandLogo({required this.branding, required this.size});

  final BusinessBranding? branding;
  final double size;

  @override
  Widget build(BuildContext context) {
    final uri = branding?.logoUri;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(
        Icons.storefront_rounded,
        size: 20,
        color: Colors.white,
      ),
    );
    if (uri == null) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        child: Image.network(
          uri.toString(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}
