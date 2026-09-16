import 'package:flutter/material.dart';
import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';
import '../presentation/controllers/empleados_controller.dart';
import '../presentation/controllers/historial_pagos_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/global_date_filter.dart';

class HistorialPagosEmpleadoPage extends ConsumerStatefulWidget {
  final Map<String, dynamic>? empleado;

  const HistorialPagosEmpleadoPage({super.key, this.empleado});

  @override
  ConsumerState<HistorialPagosEmpleadoPage> createState() =>
      _HistorialPagosEmpleadoPageState();
}

class _HistorialPagosEmpleadoPageState
    extends ConsumerState<HistorialPagosEmpleadoPage> {
  int? _empleadoSeleccionadoId;
  bool _generandoPdf = false;
  final GlobalDateFilterState _dateFilter = GlobalDateFilterState();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _empleadoSeleccionadoId = widget.empleado?['id'];

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        ref.read(historialPagosNotifierProvider.notifier).loadMore();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cargarDatos();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _exportPdf() async {
    if (_generandoPdf) return;
    setState(() => _generandoPdf = true);
    try {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Generando PDF...')));
      }

      final repository = ref.read(empleadosRepositoryProvider);
      final pagosParaPdf = await repository.obtenerHistorialPagosParaPdf(
        empleadoId: _empleadoSeleccionadoId,
        fechaInicio: _dateFilter.fechaInicio,
        fechaFin: _dateFilter.fechaFin,
      );

      if (pagosParaPdf.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No hay pagos para exportar en este rango'),
            ),
          );
        }
        return;
      }

      double totalMontoPdf = 0;
      for (var p in pagosParaPdf) {
        totalMontoPdf += (p['monto'] as num).toDouble();
      }

      if (!mounted) return;

      final empName = _empleadoSeleccionadoId == null
          ? 'Todos los Empleados'
          : (ref
                    .read(empleadosNotifierProvider)
                    .valueOrNull
                    ?.empleados
                    .firstWhere(
                      (e) => e['id'] == _empleadoSeleccionadoId,
                      orElse: () => {'nombre': 'Desconocido'},
                    )['nombre'] ??
                'Desconocido');

      final document = await HistorialPagosPdfService.generar(
        pagos: pagosParaPdf,
        nombreEmpleado: empName.toString(),
        rangoFechas:
            "${_dateFilter.filtroTipo} - ${_dateFilter.textoFechaBase}",
        total: totalMontoPdf,
      );

      if (!context.mounted) return;
      final result = await documentOutputFor(context).deliver(document);
      if (result == DocumentOutputResult.saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF guardado exitosamente')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
      }
    } finally {
      if (mounted) setState(() => _generandoPdf = false);
    }
  }

  void _cargarDatos() {
    ref
        .read(historialPagosNotifierProvider.notifier)
        .loadInitialData(
          empleadoId: _empleadoSeleccionadoId,
          fechaInicio: _dateFilter.fechaInicio,
          fechaFin: _dateFilter.fechaFin,
        );
  }

  void _seleccionarFechaEspecifica() {
    GlobalDateFilterWidget.seleccionarFechaEspecifica(
      context: context,
      filterState: _dateFilter,
      primaryColor: AppColors.personal,
      onSelected: (date) {
        setState(() {
          _dateFilter.fechaEspecifica = date;
        });
        _cargarDatos();
      },
    );
  }

  void _seleccionarRango() {
    GlobalDateFilterWidget.seleccionarRango(
      context: context,
      primaryColor: AppColors.personal,
      onSelected: (rango) {
        setState(() {
          _dateFilter.rangoPersonalizado = rango;
          _dateFilter.filtroTipo = 'Personalizado';
        });
        _cargarDatos();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(historialPagosNotifierProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Historial de Pagos',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            GlobalDateFilterWidget.buildTitleWidget(
              filterState: _dateFilter,
              onSelectFechaEspecifica: _seleccionarFechaEspecifica,
            ),
          ],
        ),
        backgroundColor: AppColors.personal,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          Theme(
            data: Theme.of(context).copyWith(
              popupMenuTheme: PopupMenuThemeData(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                color: Theme.of(context).cardColor,
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
              onSelected: (value) {
                if (['Diario', 'Semanal', 'Mensual', 'Anual'].contains(value)) {
                  setState(() {
                    _dateFilter.filtroTipo = value;
                  });
                  _cargarDatos();
                }
                if (value == 'Personalizado') _seleccionarRango();
              },
              itemBuilder: (context) {
                List<PopupMenuEntry<String>> opciones = [];
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
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.grey[800]
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "FILTROS DE FECHA",
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[300]
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
                                ? AppColors.personal
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
                return opciones;
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Theme.of(context).cardColor,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(
                        Icons.person,
                        color: AppColors.personal,
                      ),
                    ),
                    initialValue: _empleadoSeleccionadoId,
                    hint: const Text("Todos los empleados"),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text(
                          "Todos los empleados",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      ...ref
                          .watch(
                            empleadosNotifierProvider.select(
                              (s) => s.value?.empleados ?? [],
                            ),
                          )
                          .map(
                            (e) => DropdownMenuItem(
                              value: e['id'] as int,
                              child: Text(e['nombre'] ?? 'Desconocido'),
                            ),
                          ),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _empleadoSeleccionadoId = val;
                      });
                      _cargarDatos();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _generandoPdf ? null : _exportPdf,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Icon(Icons.picture_as_pdf, color: Colors.red),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: asyncState.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text(ErrorMapper.map(e), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _cargarDatos,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (state) {
                if (state.isLoading && state.pagos.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                final pagos = state.pagos;

                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 15,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.personal.withValues(alpha: 0.25)
                            : AppColors.personal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: AppColors.personal.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Total Pagado en Rango",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            AppFormatters.currency(state.totalMontoRango),
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: AppColors.personal,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                    ),

                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () => ref
                            .read(historialPagosNotifierProvider.notifier)
                            .refresh(),
                        color: AppColors.personal,
                        child: pagos.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  SizedBox(
                                    height:
                                        MediaQuery.of(context).size.height *
                                        0.2,
                                  ),
                                  Icon(
                                    Icons.history_toggle_off,
                                    size: 60,
                                    color: Colors.grey[300],
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    "No se encontraron pagos\npara este rango de fechas",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.only(
                                  left: 16,
                                  right: 16,
                                  bottom: 20,
                                ),
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: pagos.length + 1,
                                itemBuilder: (ctx, i) {
                                  if (i == pagos.length) {
                                    if (state.isFetchingMore) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 20,
                                        ),
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  }

                                  final p = pagos[i];
                                  final esAdelanto = p['concepto']
                                      .toString()
                                      .toLowerCase()
                                      .contains('adelanto');
                                  final metodoPago = p['metodo'] ?? 'Efectivo';
                                  final fechaFmt =
                                      AppFormatters.limaDateTimeText(
                                        p['fecha'],
                                      );
                                  final empNombre =
                                      p['empleados']?['nombre'] ??
                                      'Empleado Desconocido';

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).cardColor,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.grey.shade800
                                            : Colors.grey.shade200,
                                      ),
                                      boxShadow:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? []
                                          : [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.02,
                                                ),
                                                blurRadius: 5,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                    ),
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 15,
                                            vertical: 5,
                                          ),
                                      leading: CircleAvatar(
                                        backgroundColor: esAdelanto
                                            ? Colors.orange[50]
                                            : AppColors.personal.withValues(
                                                alpha: 0.1,
                                              ),
                                        child: Icon(
                                          esAdelanto
                                              ? Icons.access_time
                                              : Icons.check,
                                          color: esAdelanto
                                              ? Colors.orange
                                              : AppColors.personal,
                                          size: 20,
                                        ),
                                      ),
                                      title: Text(
                                        _empleadoSeleccionadoId == null
                                            ? "$empNombre - ${p['concepto']}"
                                            : p['concepto'],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      subtitle: Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          "$fechaFmt\nMétodo: $metodoPago",
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.grey[600],
                                            height: 1.3,
                                          ),
                                        ),
                                      ),
                                      isThreeLine: true,
                                      trailing: Text(
                                        AppFormatters.currency(
                                          (p['monto'] as num),
                                        ),
                                        style: const TextStyle(
                                          color: AppColors.personal,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
