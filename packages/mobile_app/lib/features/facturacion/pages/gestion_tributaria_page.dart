import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/estado_tributario_badge.dart';
import '../../../core/widgets/global_date_filter.dart';
import 'ver_proceso_tributario_page.dart';

class GestionTributariaPage extends ConsumerStatefulWidget {
  const GestionTributariaPage({super.key});

  @override
  ConsumerState<GestionTributariaPage> createState() =>
      _GestionTributariaPageState();
}

class _GestionTributariaPageState extends ConsumerState<GestionTributariaPage> {
  static const int _limiteSolicitudes = 50;
  static const int _limiteProcesos = 50;
  final GlobalDateFilterState _dateFilter = GlobalDateFilterState(
    filtroTipo: 'Mensual',
  );
  bool _cargando = true;
  bool _procesando = false;
  String? _errorCarga;
  List<Map<String, dynamic>> _solicitudes = [];
  List<Map<String, dynamic>> _procesos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(rolProvider) == 'admin') {
        _cargar();
      } else {
        setState(() => _cargando = false);
      }
    });
  }

  Future<void> _cargar() async {
    if (ref.read(rolProvider) != 'admin') {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    try {
      final repo = ref.read(procesosTributariosRepositoryProvider);
      final finExclusivo = DateTime(
        _dateFilter.fechaFin.year,
        _dateFilter.fechaFin.month,
        _dateFilter.fechaFin.day,
      ).add(const Duration(days: 1));

      final values = await Future.wait([
        repo.listarSolicitudes(
          fechaInicio: _dateFilter.fechaInicio,
          finExclusivo: finExclusivo,
          limite: _limiteSolicitudes,
        ),
        repo.listarProcesos(
          fechaInicio: _dateFilter.fechaInicio,
          finExclusivo: finExclusivo,
          limite: _limiteProcesos,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _solicitudes = values[0];
        _procesos = values[1];
        _errorCarga = null;
        _cargando = false;
      });
    } catch (e, st) {
      debugPrint('GestionTributariaPage: fallo de carga: $e');
      if (mounted) {
        setState(() {
          _errorCarga = ErrorMapper.map(e);
          _cargando = false;
        });
      }
      assert(() {
        debugPrintStack(stackTrace: st);
        return true;
      }());
    }
  }

  Future<void> _reintentarCarga() async {
    if (!mounted) return;
    setState(() {
      _cargando = true;
      _errorCarga = null;
    });
    await _cargar();
  }

  Future<void> _procesarBajas() async {
    if (ref.read(rolProvider) != 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solo el administrador puede procesar bajas tributarias.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_procesando) return;
    setState(() => _procesando = true);
    try {
      final result = await FacturacionService.procesarBajasTributarias();
      if (!mounted) return;
      final cantidad = (result['procesos_creados'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cantidad == 0
                ? 'No había solicitudes nuevas por procesar.'
                : 'Se crearon $cantidad proceso(s) de anulación o baja.',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.deepPurple,
        ),
      );
      await _cargar();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorMapper.map(e),
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  void _seleccionarFechaEspecifica() {
    GlobalDateFilterWidget.seleccionarFechaEspecifica(
      context: context,
      filterState: _dateFilter,
      primaryColor: Colors.deepPurple,
      onSelected: (date) {
        setState(() => _dateFilter.fechaEspecifica = date);
        _cargar();
      },
    );
  }

  void _seleccionarRango() {
    GlobalDateFilterWidget.seleccionarRango(
      context: context,
      primaryColor: Colors.deepPurple,
      onSelected: (range) {
        setState(() {
          _dateFilter.filtroTipo = 'Personalizado';
          _dateFilter.rangoPersonalizado = range;
        });
        _cargar();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const color = Colors.deepPurple;
    final esAdmin = ref.watch(rolProvider) == 'admin';
    if (!esAdmin) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Procesos tributarios',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: color,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Esta sección es exclusiva del administrador.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Procesos tributarios',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            GlobalDateFilterWidget.buildTitleWidget(
              filterState: _dateFilter,
              onSelectFechaEspecifica: _seleccionarFechaEspecifica,
            ),
          ],
        ),
        backgroundColor: color,
        iconTheme: const IconThemeData(color: Colors.white),
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
              onSelected: (val) {
                if (val == 'Personalizado') {
                  _seleccionarRango();
                } else if (val == 'procesar_bajas') {
                  _procesarBajas();
                } else {
                  setState(() => _dateFilter.filtroTipo = val);
                  _cargar();
                }
              },
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
                return [
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
                        'FILTROS DE FECHA',
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
                  for (final f in [
                    'Diario',
                    'Semanal',
                    'Mensual',
                    'Anual',
                    'Personalizado',
                  ])
                    PopupMenuItem(
                      value: f,
                      child: Row(
                        children: [
                          Icon(
                            _dateFilter.filtroTipo == f
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: _dateFilter.filtroTipo == f
                                ? color
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
                  const PopupMenuDivider(),
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
                        'ACCIONES',
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
                  PopupMenuItem(
                    value: 'procesar_bajas',
                    child: Row(
                      children: [
                        _procesando
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.cloud_sync, size: 18),
                        const SizedBox(width: 10),
                        const Text('Procesar bajas pendientes'),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: color))
          : _errorCarga != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 14),
                    Text(
                      _errorCarga!,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _reintentarCarga,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              color: color,
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Esta sección es administrativa. Aquí se revisan '
                            'solicitudes de anulación, comunicaciones de baja '
                            'y tickets SUNAT.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _titulo('Solicitudes pendientes y recientes'),
                  if (_solicitudes.isEmpty)
                    _vacio('No hay solicitudes de baja.')
                  else
                    ..._solicitudes.take(20).map(_solicitudCard),
                  const SizedBox(height: 20),
                  _titulo('Anulaciones y bajas enviadas'),
                  if (_procesos.isEmpty)
                    _vacio('Todavía no hay procesos tributarios.')
                  else
                    ..._procesos.map(_procesoCard),
                ],
              ),
            ),
    );
  }

  Widget _titulo(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
    ),
  );

  Widget _vacio(String text) => Container(
    padding: const EdgeInsets.all(18),
    margin: const EdgeInsets.only(bottom: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(text),
  );

  Widget _solicitudCard(Map<String, dynamic> s) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        leading: const Icon(Icons.pending_actions),
        title: Text('${s['serie']}-${s['correlativo']}'),
        subtitle: Text('${s['motivo']}\n${_fecha(s['created_at'])}'),
        isThreeLine: true,
        trailing: EstadoTributarioBadge(estado: s['estado']?.toString() ?? ''),
      ),
    );
  }

  Widget _procesoCard(Map<String, dynamic> p) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  VerProcesoTributarioPage(procesoId: p['id'].toString()),
            ),
          );
          if (mounted) await _cargar();
        },
        leading: Icon(
          p['tipo_proceso'] == 'resumen_boletas'
              ? Icons.receipt_long
              : Icons.cancel_schedule_send,
        ),
        title: Text(p['identificador']?.toString() ?? '-'),
        subtitle: Text(
          p['tipo_proceso'] == 'resumen_boletas'
              ? 'Anulación de boleta o nota'
              : 'Comunicación de baja',
        ),
        trailing: EstadoTributarioBadge(estado: p['estado']?.toString() ?? ''),
      ),
    );
  }

  String _fecha(dynamic value) {
    final date = value == null ? null : DateTime.tryParse(value.toString());
    return date == null ? '-' : AppFormatters.limaDateTimeLong(date);
  }
}
