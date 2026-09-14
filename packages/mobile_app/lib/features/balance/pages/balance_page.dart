import 'package:mobile_app/platform/realtime/realtime_sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/utils/navigation_utils.dart';
import '../../../home/controllers/prefetch_providers.dart';
import '../../empleados/pages/ver_pago_empleado_page.dart';
import '../../gastos/pages/nuevo_gasto_page.dart';
import '../../gastos/pages/ver_gasto_page.dart';
import '../../reportes/pages/reportes_page.dart';
import '../../ventas/pages/seleccion_productos_page.dart';
import '../../ventas/pages/ver_venta_page.dart';
import '../widgets/balance_widgets.dart';
import '../widgets/ventas_pendientes_dialog.dart';
import 'caja_chica_page.dart';

class BalancePage extends ConsumerStatefulWidget {
  const BalancePage({super.key});

  @override
  ConsumerState<BalancePage> createState() => _BalancePageState();
}

class _BalancePageState extends ConsumerState<BalancePage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late TabController _tabController;
  bool _cargando = true;
  List<Map<String, dynamic>> _ingresos = [];
  List<Map<String, dynamic>> _egresos = [];

  double _totalIngresos = 0.0;
  double _totalEgresos = 0.0;
  double _totalDescuentos = 0.0;

  final Color colorVerde = const Color(0xFF0F9D58);
  late AnimationController _fabAnimationController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    _fabAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _fabAnimationController.forward();
    
    final cache = ref.read(balanceCacheProvider);
    if (cache != null) {
      _totalIngresos = (cache['resumen']['ventas_hoy'] as num?)?.toDouble() ?? 0.0;
      _totalEgresos = (cache['resumen']['gastos_hoy'] as num?)?.toDouble() ?? 0.0;
      _ingresos = cache['ingresos'];
      _egresos = cache['egresos'];
      final ventasList = cache['ventas'] as List<Map<String, dynamic>>;
      _totalDescuentos = ventasList.fold(0.0, (sum, v) {
        final double d = (v['descuento_global_monto'] as num?)?.toDouble() ?? 0.0;
        return sum + d;
      });
      _cargando = false;
    }
    
    _cargarMovimientos(silent: cache != null);
  }

  @override
  void dispose() {
    _fabAnimationController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  DateTime get _fechaInicio => AppTime.startOfToday();

  DateTime get _fechaFin => AppTime.endOfToday();

  Future<void> _cargarMovimientos({bool silent = false}) async {
    if (!silent && mounted) setState(() => _cargando = true);

    try {
      final repo = ref.read(balanceRepositoryProvider);
      final res = await repo
          .getDashboardSummary(_fechaInicio, _fechaFin)
          .timeout(const Duration(seconds: 10));
      if (mounted) {
        _totalIngresos = (res['ventas_hoy'] as num?)?.toDouble() ?? 0.0;
        _totalEgresos = (res['gastos_hoy'] as num?)?.toDouble() ?? 0.0;
      }

      final futures = await Future.wait<List<Map<String, dynamic>>>([
        repo
            .getMovimientos('ingreso', _fechaInicio, _fechaFin)
            .timeout(const Duration(seconds: 10)),
        repo
            .getMovimientos('egreso', _fechaInicio, _fechaFin)
            .timeout(const Duration(seconds: 10)),
        repo
            .getVentasParaDescuento(_fechaInicio, _fechaFin)
            .timeout(const Duration(seconds: 10)),
      ]);

      final ingresosData = futures[0];
      final egresosData = futures[1];
      final ventasList = futures[2];

      if (mounted) {
        setState(() {
          _ingresos = ingresosData;
          _egresos = egresosData;
          _totalDescuentos = ventasList.fold(0.0, (sum, v) {
            final double d =
                (v['descuento_global_monto'] as num?)?.toDouble() ?? 0.0;
            return sum + d;
          });
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _navegarADetalleMovimiento(Map<String, dynamic> item) async {
    if (item['venta_id'] != null) {
      await AppNavigator.navegarA(
        context,
        VerVentaPage(ventaId: item['venta_id']),
      );
    } else if (item['gasto_id'] != null) {
      await AppNavigator.navegarA(
        context,
        VerGastoPage(gastoId: item['gasto_id']),
      );
    } else if (item['pago_empleado_id'] != null) {
      await AppNavigator.navegarA(
        context,
        VerPagoEmpleadoPage(pagoEmpleadoId: item['pago_empleado_id']),
      );
    }
    _cargarMovimientos(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Balance consume el canal financiero global; evita abrir un segundo canal
    // Realtime para las mismas tablas.
    ref.listen(financialRealtimeEventStreamProvider, (previous, next) {
      if (next.hasValue &&
          next.value!.requiereRecargaReportesFinancieros &&
          mounted) {
        _cargarMovimientos(silent: true);
      }
    });

    final balance = _totalIngresos - _totalEgresos;
    final isDesktop = MediaQuery.of(context).size.width > 800;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget buildTitle() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Balance Financiero',
            style: TextStyle(
              color: isDesktop
                  ? (isDark ? Colors.white : Colors.black87)
                  : Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            "Día: ${DateFormat('dd MMMM', 'es').format(AppTime.now())}",
            style: TextStyle(
              color: isDesktop
                  ? (isDark ? Colors.white70 : Colors.black54)
                  : Colors.white70,
              fontSize: 13,
            ),
          ),
        ],
      );
    }

    Widget buildActions() {
      return Theme(
        data: Theme.of(context).copyWith(
          popupMenuTheme: PopupMenuThemeData(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            elevation: 10,
          ),
        ),
        child: PopupMenuButton<String>(
          offset: const Offset(0, 55),
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isDesktop
                  ? (isDark
                        ? Colors.white12
                        : Colors.grey.withValues(alpha: 0.2))
                  : (isDark
                        ? Colors.black.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.15)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.tune_rounded,
              color: isDesktop
                  ? (isDark ? Colors.white : Colors.black87)
                  : Colors.white,
              size: 22,
            ),
          ),
          onSelected: (value) {
            if (value == 'caja_chica') {
              AppNavigator.navegarA(context, const CajaChicaPage());
            }
            if (value == 'sincronizar_offline') {
              showDialog(
                context: context,
                builder: (ctx) =>
                    VentasPendientesDialog(onSyncComplete: _cargarMovimientos),
              );
            }
          },
          itemBuilder: (context) {
            return <PopupMenuEntry<String>>[
              buildMenuItemElegante(
                context: context,
                value: 'caja_chica',
                icon: Icons.point_of_sale_rounded,
                iconColor: Theme.of(context).colorScheme.primary,
                text: 'Caja Chica',
              ),
              const PopupMenuDivider(),
              buildMenuItemElegante(
                context: context,
                value: 'sincronizar_offline',
                icon: Icons.sync_rounded,
                iconColor: Colors.blueAccent,
                text: 'Sincronizar Ventas',
              ),
            ];
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: !isDesktop,
      appBar: isDesktop
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              title: buildTitle(),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [buildActions(), const SizedBox(width: 8)],
            ),
      body: SafeArea(
        top: isDesktop,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final resumenCard = BalanceResumenCard(
              balance: balance,
              ingresos: _totalIngresos,
              egresos: _totalEgresos,
              descuentos: _totalDescuentos,
              onVerDetalle: () =>
                  AppNavigator.navegarA(context, const ReportesPage()),
            );

            final tabsHeader = BalanceTabsHeader(tabController: _tabController);
            final tabVistas = TabBarView(
              controller: _tabController,
              children: [
                _cargando && _ingresos.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : MovimientosList(
                        movimientos: _ingresos,
                        tipo: 'ingreso',
                        onItemTap: _navegarADetalleMovimiento,
                        onRefresh: () async => _cargarMovimientos(),
                      ),
                _cargando && _egresos.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : MovimientosList(
                        movimientos: _egresos,
                        tipo: 'egreso',
                        onItemTap: _navegarADetalleMovimiento,
                        onRefresh: () async => _cargarMovimientos(),
                      ),
              ],
            );
            final tabVistasConRefresh = RefreshIndicator(
              onRefresh: () async => _cargarMovimientos(),
              color: colorVerde,
              child: tabVistas,
            );

            if (isDesktop) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [buildTitle(), buildActions()],
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              children: [
                                resumenCard,
                                const SizedBox(height: 25),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: () async {
                                          await AppNavigator.navegarA(
                                            context,
                                            const SeleccionProductosV2(),
                                          );
                                          _cargarMovimientos();
                                        },
                                        icon: const Icon(
                                          Icons.add_shopping_cart,
                                          size: 20,
                                        ),
                                        label: const Text('VENTA'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 18,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          elevation: 4,
                                          textStyle: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 15),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: () async {
                                          await AppNavigator.navegarA(
                                            context,
                                            const NuevoGastoPage(),
                                          );
                                          _cargarMovimientos();
                                        },
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                          size: 20,
                                        ),
                                        label: const Text('GASTO'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red[700],
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 18,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          elevation: 4,
                                          textStyle: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 25),
                                tabsHeader,
                              ],
                            ),
                          ),
                          const SizedBox(width: 25),
                          Expanded(
                            flex: 7,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).cardColor,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  if (!isDark)
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.05,
                                      ),
                                      blurRadius: 10,
                                    ),
                                ],
                              ),
                              child: Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Text(
                                      'Historial de Movimientos',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.grey[800],
                                      ),
                                    ),
                                  ),
                                  const Divider(
                                    height: 1,
                                    color: Colors.black12,
                                  ),
                                  Expanded(child: tabVistasConRefresh),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                resumenCard,
                const SizedBox(height: 15),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  child: tabsHeader,
                ),
                Expanded(child: tabVistasConRefresh),
              ],
            );
          },
        ),
      ),
    );
  }
}
