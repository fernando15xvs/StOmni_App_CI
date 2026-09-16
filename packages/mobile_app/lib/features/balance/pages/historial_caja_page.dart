import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import '../widgets/historial_caja_detalle_tile.dart';

class HistorialCajaPage extends ConsumerStatefulWidget {
  const HistorialCajaPage({super.key});

  @override
  ConsumerState<HistorialCajaPage> createState() => _HistorialCajaPageState();
}

class _HistorialCajaPageState extends ConsumerState<HistorialCajaPage> {
  bool _cargando = true;
  String? _errorCarga;
  List<Map<String, dynamic>> _sesiones = const [];
  String _filtroSeleccionado = 'Semanal';
  final List<String> _filtros = const [
    'Semanal',
    'Mensual',
    'Anual',
    'Personalizado',
  ];
  DateTime? _fechaInicio;
  DateTime? _fechaFin;

  @override
  void initState() {
    super.initState();
    _cargarHistorial();
  }

  Future<void> _cargarHistorial() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }
    try {
      final ahora = AppTime.now();
      DateTime? desde;
      DateTime? hasta;

      switch (_filtroSeleccionado) {
        case 'Semanal':
          final inicio = ahora.subtract(Duration(days: ahora.weekday - 1));
          desde = DateTime(inicio.year, inicio.month, inicio.day);
        case 'Mensual':
          desde = DateTime(ahora.year, ahora.month, 1);
        case 'Anual':
          desde = DateTime(ahora.year, 1, 1);
        case 'Personalizado':
          desde = _fechaInicio;
          hasta = _fechaFin;
      }

      final sesiones = await ref
          .read(balanceRepositoryProvider)
          .getHistorialCaja(desde, hasta);
      if (mounted) {
        setState(() {
          _sesiones = sesiones;
          _errorCarga = null;
          _cargando = false;
        });
      }
    } catch (e, st) {
      debugPrint('HistorialCajaPage: fallo al cargar historial: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() {
        _errorCarga = ErrorMapper.map(e);
        _cargando = false;
      });
    }
  }

  Future<void> _seleccionarRangoFechas() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: AppTime.now(),
      initialDateRange: _fechaInicio != null && _fechaFin != null
          ? DateTimeRange(start: _fechaInicio!, end: _fechaFin!)
          : null,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _fechaInicio = picked.start;
        _fechaFin = picked.end;
        _filtroSeleccionado = 'Personalizado';
      });
      await _cargarHistorial();
    } else if (_fechaInicio == null || _fechaFin == null) {
      setState(() => _filtroSeleccionado = 'Semanal');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.grey[50],
      appBar: AppBar(
        title: const Text('Historial', style: TextStyle(color: Colors.white)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _filtroSeleccionado,
                dropdownColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                icon: const Icon(
                  Icons.filter_alt_outlined,
                  color: Colors.white,
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                selectedItemBuilder: (_) => _filtros.map<Widget>((item) {
                  return Center(
                    child: Text(
                      item == 'Personalizado' && _fechaInicio != null
                          ? '${DateFormat('dd/MM').format(_fechaInicio!)} - ${DateFormat('dd/MM').format(_fechaFin!)}'
                          : item,
                      style: const TextStyle(color: Colors.white),
                    ),
                  );
                }).toList(),
                items: _filtros.map((value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(
                      value,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (newValue) {
                  if (newValue == 'Personalizado') {
                    _seleccionarRangoFechas();
                  } else if (newValue != null) {
                    setState(() {
                      _filtroSeleccionado = newValue;
                      _fechaInicio = null;
                      _fechaFin = null;
                    });
                    _cargarHistorial();
                  }
                },
              ),
            ),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _errorCarga != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 52),
                    const SizedBox(height: 16),
                    Text(_errorCarga!, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _cargarHistorial,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : _sesiones.isEmpty
          ? const Center(
              child: Text(
                'No hay turnos cerrados en este periodo.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : RefreshIndicator(
              onRefresh: _cargarHistorial,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _sesiones.length,
                itemBuilder: (_, index) =>
                    HistorialCajaDetalleTile(s: _sesiones[index]),
              ),
            ),
    );
  }
}
