import 'package:mobile_app/platform/realtime/realtime_sync_service.dart';
import 'package:core_logic/core_logic.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reportes_provider.dart';
import 'package:shimmer/shimmer.dart';
import 'dart:async';
import '../../../core/widgets/global_date_filter.dart';
import '../../../core/utils/navigation_utils.dart';
import '../../ventas/pages/ver_venta_page.dart';
import '../../gastos/pages/ver_gasto_page.dart';
import '../../empleados/pages/ver_pago_empleado_page.dart';
import 'exportar_reportes_page.dart';
import 'exportar_inventario_pdf_page.dart';
import 'detalle_balance_page.dart';
import '../../shared/widgets/product_search_widget.dart';

class ReportesPage extends ConsumerStatefulWidget {
  const ReportesPage({super.key});

  @override
  ConsumerState<ReportesPage> createState() => _ReportesPageState();
}

class _ReportesPageState extends ConsumerState<ReportesPage>
    with SingleTickerProviderStateMixin {
  Widget _buildSilentSyncIndicator() {
    final state = ref.watch(reportesProvider);
    if (state.isSilentSyncing) {
      return const PreferredSize(
        preferredSize: Size.fromHeight(3),
        child: LinearProgressIndicator(
          minHeight: 3,
          backgroundColor: Colors.transparent,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  late TabController _tabController;
  int _tabIndex = 0;
  final GlobalDateFilterState _dateFilter = GlobalDateFilterState();
  String _tipoFiltroFinanciero = 'Todos';
  String _tipoFiltroInventario = 'Todos';
  int? _productoFiltroId;
  String? _productoFiltroNombre;
  Timer? _reportesRefreshDebounce;

  @override
  void initState() {
    super.initState();
    ref.read(realtimeFinancialSyncServiceProvider);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        if (_tabIndex != _tabController.index) {
          setState(() => _tabIndex = _tabController.index);
        }
        _cargarDatos();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cargarDatos();
    });
  }

  void _onDataChanged() {
    _reportesRefreshDebounce?.cancel();
    _reportesRefreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _cargarDatos(silent: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    _reportesRefreshDebounce?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _cargarDatos({bool silent = false, bool force = false}) {
    if (!mounted) return;
    final revInv = ref.read(reportesInventarioRevisionProvider);
    final revFin = ref.read(reportesFinancierosRevisionProvider);
    ref
        .read(reportesProvider.notifier)
        .cargarDatos(
          ReportesParams(_dateFilter.fechaInicio, _dateFilter.fechaFin),
          revInv,
          revFin,
          silent: silent,
          force: force,
        );
  }

  Future<void> _seleccionarFechaEspecifica() async {
    await GlobalDateFilterWidget.seleccionarFechaEspecifica(
      context: context,
      filterState: _dateFilter,
      primaryColor: AppColors.reportes,
      onSelected: (date) {
        setState(() => _dateFilter.fechaEspecifica = date);
        _cargarDatos();
      },
    );
  }

  Future<void> _seleccionarRango() async {
    await GlobalDateFilterWidget.seleccionarRango(
      context: context,
      primaryColor: AppColors.reportes,
      onSelected: (range) {
        setState(() {
          _dateFilter.filtroTipo = 'Personalizado';
          _dateFilter.rangoPersonalizado = range;
        });
        _cargarDatos();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reportesInventarioRevisionProvider, (prev, next) {
      _onDataChanged();
    });
    ref.listen(reportesFinancierosRevisionProvider, (prev, next) {
      _onDataChanged();
    });
    ref.listen<ReportesData>(reportesProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.error!), backgroundColor: Colors.red),
        );
      }
    });
    bool esPantallaGrande = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        toolbarHeight: 76,
        titleSpacing: 0,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reportes',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            GlobalDateFilterWidget.buildTitleWidget(
              filterState: _dateFilter,
              onSelectFechaEspecifica: _seleccionarFechaEspecifica,
            ),
          ],
        ),
        backgroundColor: AppColors.reportes,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(51),
          child: Column(
            children: [
              TabBar(
                controller: _tabController,
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.normal,
                ),
                tabs: const [
                  Tab(text: "Financiero", icon: Icon(Icons.attach_money)),
                  Tab(
                    text: "Inventario",
                    icon: Icon(Icons.inventory_2_rounded),
                  ),
                ],
              ),
              _buildSilentSyncIndicator(),
            ],
          ),
        ),
        actions: [
          if (_tabIndex == 1)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_rounded),
              tooltip: 'Exportar PDF de Inventario',
              onPressed: () {
                AppNavigator.navegarA(
                  context,
                  ExportarInventarioPdfPage(
                    fechaInicio: _dateFilter.fechaInicio,
                    fechaFin: _dateFilter.fechaFin,
                  ),
                );
              },
            ),
          if (_tabIndex == 0)
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Generar reporte',
              onPressed: () {
                AppNavigator.navegarA(
                  context,
                  ExportarReportesPage(
                    fechaInicio: _dateFilter.fechaInicio,
                    fechaFin: _dateFilter.fechaFin,
                  ),
                );
              },
            ),
          if (esPantallaGrande && _dateFilter.filtroTipo == 'Diario')
            IconButton(
              icon: const Icon(Icons.date_range_rounded),
              tooltip: "Cambiar Día",
              onPressed: _seleccionarFechaEspecifica,
            ),
          if (esPantallaGrande) ...[
            GlobalDateFilterWidget.buildDropdownFilter(
              context: context,
              filterState: _dateFilter,
              primaryColor: AppColors.reportes,
              onChanged: (val) {
                setState(() => _dateFilter.filtroTipo = val);
                _cargarDatos();
              },
              onSelectRango: _seleccionarRango,
            ),
          ],
          if (!esPantallaGrande)
            Theme(
              data: Theme.of(context).copyWith(
                popupMenuTheme: PopupMenuThemeData(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[900]
                      : Colors.white,
                  elevation: 10,
                ),
              ),
              child: PopupMenuButton<String>(
                offset: const Offset(0, 55),
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                itemBuilder: (context) {
                  List<PopupMenuEntry<String>> opciones = [];
                  if (!esPantallaGrande) {
                    opciones.add(
                      PopupMenuItem(
                        enabled: false,
                        height: 30,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey[800]
                                : Colors.grey[100],
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            "FILTROS DE FECHA",
                            style: TextStyle(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white70
                                  : Colors.black54,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    );
                    for (String f in [
                      'Diario',
                      'Semanal',
                      'Mensual',
                      'Anual',
                      'Personalizado',
                    ]) {
                      opciones.add(
                        PopupMenuItem(
                          value: f,
                          child: Row(
                            children: [
                              Icon(
                                _dateFilter.filtroTipo == f
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: _dateFilter.filtroTipo == f
                                    ? AppColors.reportes
                                    : Colors.grey,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                f,
                                style: TextStyle(
                                  fontWeight: _dateFilter.filtroTipo == f
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    opciones.add(const PopupMenuDivider());
                  }
                  return opciones;
                },
                onSelected: (value) {
                  if ([
                    'Diario',
                    'Semanal',
                    'Mensual',
                    'Anual',
                  ].contains(value)) {
                    setState(() => _dateFilter.filtroTipo = value);
                    _cargarDatos();
                  } else if (value == 'Personalizado') {
                    _seleccionarRango();
                  }
                },
              ),
            ),
          const SizedBox(width: 5),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildFinancieroTab(), _buildInventarioTab()],
      ),
    );
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
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.grey.shade300,
      highlightColor: Colors.grey.shade100,
      child: ListView.builder(
        padding: const EdgeInsets.only(
          bottom: 90,
          top: 15,
          left: 16,
          right: 16,
        ),
        itemCount: 8,
        itemBuilder: (_, _) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          height: 80,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }

  Widget _buildFinancieroTab() {
    double ingresos = 0;
    double egresos = 0;
    final movimientosFinancieros = ref.watch(
      reportesProvider.select((s) => s.financieros),
    );
    final totalDescuentos = ref.watch(
      reportesProvider.select((s) => s.totalDescuentos),
    );
    for (final m in movimientosFinancieros) {
      final monto = (m['monto'] as num?)?.toDouble() ?? 0;
      if (m['tipo'] == 'ingreso') ingresos += monto;
      if (m['tipo'] == 'egreso') egresos += monto;
    }
    final flujoNeto = ingresos - egresos;

    final filtrados = movimientosFinancieros.where((m) {
      if (_tipoFiltroFinanciero == 'Ingresos' && m['tipo'] != 'ingreso') {
        return false;
      }
      if (_tipoFiltroFinanciero == 'Egresos' && m['tipo'] != 'egreso') {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          decoration: BoxDecoration(
            color: AppColors.reportes,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(25),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[900]
                  : Colors.white,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                GestureDetector(
                  onTap: () => setState(() => _tipoFiltroFinanciero = 'Todos'),
                  child: Container(
                    color: Colors.transparent,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "FLUJO NETO",
                          style: TextStyle(
                            color: _tipoFiltroFinanciero == 'Todos'
                                ? AppColors.reportes
                                : Colors.grey,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 1.0,
                          ),
                        ),
                        Text(
                          AppFormatters.currency(flujoNeto),
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            color: flujoNeto >= 0
                                ? AppColors.reportes
                                : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                const Divider(height: 1, color: Colors.black12),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _tipoFiltroFinanciero = 'Ingresos'),
                        child: Container(
                          color: Colors.transparent,
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.arrow_circle_up_rounded,
                                    size: 16,
                                    color: AppColors.reportes,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      "Ingresos",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            _tipoFiltroFinanciero == 'Ingresos'
                                            ? AppColors.reportes
                                            : Colors.grey,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                AppFormatters.currency(ingresos),
                                style: const TextStyle(
                                  color: AppColors.reportes,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Container(width: 1, height: 40, color: Colors.grey[200]),
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _tipoFiltroFinanciero = 'Egresos'),
                        child: Container(
                          color: Colors.transparent,
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.arrow_circle_down_rounded,
                                    size: 16,
                                    color: Colors.red,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    "Egresos",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _tipoFiltroFinanciero == 'Egresos'
                                          ? Colors.red
                                          : Colors.grey,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                AppFormatters.currency(egresos),
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (totalDescuentos > 0) ...[
                      Container(width: 1, height: 40, color: Colors.grey[200]),
                      Expanded(
                        child: Container(
                          color: Colors.transparent,
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.loyalty_rounded,
                                    size: 16,
                                    color: Colors.orange,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      "Descuentos",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.orange,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                AppFormatters.currency(totalDescuentos),
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 30,
                  child: OutlinedButton(
                    onPressed: () {
                      AppNavigator.navegarA(
                        context,
                        DetalleBalancePage(
                          fechaInicio: _dateFilter.fechaInicio,
                          fechaFin: _dateFilter.fechaFin,
                          movimientos: movimientosFinancieros,
                          totalDescuentos: totalDescuentos,
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(side: BorderSide.none),
                    child: const Text(
                      "Distribución por Método de Pago >",
                      style: TextStyle(fontSize: 12, color: AppColors.reportes),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey[900]
                : Colors.grey[200],
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: ['Todos', 'Ingresos', 'Egresos'].map((tipo) {
              final isSelected = _tipoFiltroFinanciero == tipo;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tipoFiltroFinanciero = tipo),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Theme.of(context).cardColor
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Text(
                        tipo,
                        style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w600,
                          fontSize: 14,
                          color: isSelected
                              ? AppColors.reportes
                              : Colors.grey[600],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: ref.watch(reportesProvider.select((s) => s.isLoading))
              ? _buildShimmerLoading()
              : filtrados.isEmpty
              ? const Center(
                  child: Text(
                    "No hay movimientos en este periodo",
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    bottom: 90,
                    top: 15,
                    left: 16,
                    right: 16,
                  ),
                  itemCount: filtrados.length,
                  itemBuilder: (context, index) {
                    final item = filtrados[index];
                    final esIngreso = item['tipo'] == 'ingreso';
                    final descripcion = item['descripcion'] ?? 'Movimiento';
                    final monto = (item['monto'] as num).toDouble();

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _navegarADetalleMovimiento(item),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                            borderRadius: BorderRadius.circular(20),
                            border:
                                Theme.of(context).brightness == Brightness.dark
                                ? null
                                : Border.all(color: Colors.grey.shade100),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.02),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(11),
                                decoration: BoxDecoration(
                                  color: esIngreso
                                      ? (Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? AppColors.reportes.withValues(
                                                alpha: 0.15,
                                              )
                                            : AppColors.reportes.shade50)
                                      : (Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.red.withValues(alpha: 0.15)
                                            : Colors.red.shade50),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  esIngreso
                                      ? Icons.trending_up_rounded
                                      : Icons.trending_down_rounded,
                                  color: esIngreso
                                      ? AppColors.reportes
                                      : Colors.red,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      descripcion,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.white
                                            : const Color(0xFF1E293B),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      AppFormatters.limaDateTime(item['fecha']),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[500],
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    "${esIngreso ? '+' : '-'} ${AppFormatters.currency(monto)}",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15,
                                      color: esIngreso
                                          ? AppColors.reportes.shade700
                                          : Colors.red.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        "Ver detalle",
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey.shade400,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 15,
                                        color: Colors.grey.shade400,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _obtenerSubtipoMovimiento(Map<String, dynamic> item) {
    return InventarioMovimientoUtils.subtipo(item);
  }

  String _formatReportQtyAndUnit(Map<String, dynamic> item, dynamic cantRaw) {
    return InventarioMovimientoUtils.formatCantidad(item, cantRaw);
  }

  Widget _buildInventarioTab() {
    final movimientosInventario = ref.watch(
      reportesProvider.select((s) => s.inventario),
    );
    final filtrados = movimientosInventario.where((m) {
      final subtipo = _obtenerSubtipoMovimiento(m);
      if (_tipoFiltroInventario == 'Ingresos') {
        if (!subtipo.startsWith('Entrada') || subtipo.contains('Traslado')) {
          return false;
        }
      } else if (_tipoFiltroInventario == 'Salidas') {
        if (!subtipo.startsWith('Salida') || subtipo.contains('Traslado')) {
          return false;
        }
      } else if (_tipoFiltroInventario == 'Traslados') {
        if (!subtipo.contains('Traslado')) return false;
      }
      if (_productoFiltroId != null) {
        final productoId = (m['producto_id'] as num?)?.toInt();
        if (productoId != _productoFiltroId) return false;
      }
      return true;
    }).toList();

    int totalEntradas = 0;
    int totalSalidas = 0;
    int movsEntrada = 0;
    int movsSalida = 0;

    for (var m in filtrados) {
      final subtipo = _obtenerSubtipoMovimiento(m);
      if (_tipoFiltroInventario != 'Traslados' &&
          subtipo.contains('Traslado')) {
        continue;
      }
      final cantLegacy = ((m['cantidad'] as num?)?.toInt() ?? 0).abs();
      if (subtipo.startsWith('Entrada')) {
        totalEntradas += (m['ingreso_cant'] as num?)?.toInt() ?? cantLegacy;
        movsEntrada++;
      } else {
        totalSalidas += (m['salida_cant'] as num?)?.toInt() ?? cantLegacy;
        movsSalida++;
      }
    }
    final balance = totalEntradas - totalSalidas;

    String txtEntradas = "";
    String txtSalidas = "";
    String txtBalance = "";

    if (filtrados.isNotEmpty) {
      final firstItem = filtrados.first;
      final firma = InventarioMovimientoUtils.firmaFormato(firstItem);
      final bool esUnSoloProducto = filtrados.every(
        (m) =>
            m['producto_id'] == firstItem['producto_id'] &&
            InventarioMovimientoUtils.firmaFormato(m) == firma,
      );

      if (esUnSoloProducto) {
        txtEntradas = _formatReportQtyAndUnit(firstItem, totalEntradas);
        txtSalidas = _formatReportQtyAndUnit(firstItem, totalSalidas);
        final balFormateado = _formatReportQtyAndUnit(firstItem, balance.abs());
        txtBalance = balance < 0 ? "- $balFormateado" : "+ $balFormateado";
      } else {
        txtEntradas = "$movsEntrada oper.";
        txtSalidas = "$movsSalida oper.";
        txtBalance = "-";
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: ProductSearchWidget(
            initialValue: _productoFiltroNombre,
            onSearch: (q) => ref
                .read(almacenRepositoryProvider)
                .buscarProductosRapido(q, incluirInactivos: true),
            primaryColor: AppColors.reportes,
            onProductoSelected: (p) {
              setState(() {
                _productoFiltroId = (p['id'] as num?)?.toInt();
                _productoFiltroNombre = p['nombre']?.toString();
              });
            },
            onCleared: () {
              setState(() {
                _productoFiltroId = null;
                _productoFiltroNombre = null;
              });
            },
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey[900]
                : Colors.grey[200],
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: ['Todos', 'Ingresos', 'Salidas', 'Traslados'].map((tipo) {
              final isSelected = _tipoFiltroInventario == tipo;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tipoFiltroInventario = tipo),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey[800]
                                : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Text(
                        tipo,
                        style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w600,
                          fontSize: 13,
                          color: isSelected
                              ? (Theme.of(context).brightness == Brightness.dark
                                    ? Colors.white
                                    : AppColors.reportes)
                              : (Theme.of(context).brightness == Brightness.dark
                                    ? Colors.grey[400]
                                    : Colors.grey[600]),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        if (filtrados.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[900]
                  : AppColors.reportes.shade50,
              borderRadius: BorderRadius.circular(15),
              border: Theme.of(context).brightness == Brightness.dark
                  ? Border.all(color: Colors.grey[800]!)
                  : Border.all(color: AppColors.reportes.shade200),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Total Entradas:",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.reportes
                            : AppColors.reportes.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Total Salidas:",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.redAccent
                            : Colors.deepOrange.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Balance:",
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      txtEntradas,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.reportes
                            : AppColors.reportes.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      txtSalidas,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.redAccent
                            : Colors.deepOrange.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      txtBalance,
                      style: TextStyle(
                        fontSize: 14,
                        color: balance >= 0
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.reportes
                                  : AppColors.reportes.shade800)
                            : (Theme.of(context).brightness == Brightness.dark
                                  ? Colors.redAccent
                                  : Colors.red.shade800),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: ref.watch(reportesProvider.select((s) => s.isLoading))
              ? _buildShimmerLoading()
              : filtrados.isEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 60,
                      color: Colors.grey.shade300,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "El reporte de inventario está vacío.",
                      style: TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    bottom: 90,
                    top: 10,
                    left: 16,
                    right: 16,
                  ),
                  itemCount: filtrados.length,
                  itemBuilder: (context, index) {
                    final item = filtrados[index];
                    final subtipo = _obtenerSubtipoMovimiento(item);
                    final esIngreso = subtipo.startsWith('Entrada');
                    final nombre = item['producto_nombre'] ?? 'Desconocido';
                    final almacenNombre =
                        item['almacen_nombre'] ?? 'Sin almacén';
                    final cantLegacy = (item['cantidad'] as num?)
                        ?.toInt()
                        .abs();
                    final cant =
                        (esIngreso
                            ? item['ingreso_cant']
                            : item['salida_cant']) ??
                        cantLegacy;
                    final qtyFormateada = _formatReportQtyAndUnit(item, cant);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(15),
                        border: Theme.of(context).brightness == Brightness.dark
                            ? null
                            : Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 5,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: esIngreso
                                  ? (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? AppColors.reportes.withValues(
                                            alpha: 0.15,
                                          )
                                        : AppColors.reportes.shade50)
                                  : (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.orange.withValues(alpha: 0.15)
                                        : Colors.orange.shade50),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              esIngreso
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                              color: esIngreso
                                  ? AppColors.reportes
                                  : Colors.orange,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nombre,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.white
                                        : const Color(0xFF1E293B),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "$subtipo • $almacenNombre",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: esIngreso
                                        ? AppColors.reportes.shade700
                                        : Colors.orange.shade800,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppFormatters.limaMediumDateTime(
                                    item['fecha'],
                                  ),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            "${esIngreso ? '+' : '-'} $qtyFormateada",
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              color: esIngreso
                                  ? AppColors.reportes.shade700
                                  : Colors.orange.shade700,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
