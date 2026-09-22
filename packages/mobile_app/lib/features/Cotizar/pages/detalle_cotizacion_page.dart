import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../ventas/data/ventas_repository.dart';
import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/document_form_kit.dart';
import '../../../home/controllers/home_controller.dart';
import '../../../home/home_notifier.dart';

class DetalleCotizacionPage extends ConsumerStatefulWidget {
  final SaleCart carritoConPreciosFinales;
  final double totalAPagar;

  const DetalleCotizacionPage({
    super.key,
    required this.carritoConPreciosFinales,
    required this.totalAPagar,
  });

  @override
  ConsumerState<DetalleCotizacionPage> createState() =>
      _DetalleCotizacionPageState();
}

class _DetalleCotizacionPageState extends ConsumerState<DetalleCotizacionPage> {
  final _rucCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final _validezCtrl = TextEditingController(text: '15');

  DateTime _fecha = AppTime.now();
  bool _guardando = false;
  final String _requestId = const Uuid().v4();

  final Color colorTema = AppDocColors.cotizacion;

  double get _totalCalculado {
    return widget.carritoConPreciosFinales.totalAmount;
  }

  String? _validar() {
    if (widget.carritoConPreciosFinales.isEmpty) {
      return 'La cotización no contiene productos.';
    }

    final validez = int.tryParse(_validezCtrl.text.trim()) ?? 0;
    if (validez < 1 || validez > 3650) {
      return 'La validez debe estar entre 1 y 3650 días.';
    }

    if (_totalCalculado <= 0) {
      return 'El total de la cotización debe ser mayor a S/ 0.00.';
    }

    if ((_totalCalculado - widget.totalAPagar).abs() > 0.02) {
      return 'El total cambió. Regresa a Definir Precios.';
    }

    return null;
  }

  List<SaleProcessingLine> _construirDetalles() => widget
      .carritoConPreciosFinales
      .lines
      .map(
        (line) => SaleLinePersistenceMapper.map(
          line,
          requireExactTotals: true,
        ),
      )
      .toList(growable: false);

  Future<void> _procesarCotizacion() async {
    if (_guardando) return;

    final error = _validar();
    if (error != null) {
      _mostrarError(error);
      return;
    }

    setState(() => _guardando = true);

    try {
      final detalles = _construirDetalles();
      final clienteId = await ref
          .read(documentDataGatewayProvider)
          .resolverCliente(
            ruc: _rucCtrl.text,
            nombre: _nombreClienteCtrl.text,
            direccion: _direccionCtrl.text,
          );

      final cotizacionId = await ref
          .read(ventasRepositoryProvider)
          .guardarCotizacion(
            requestId: _requestId,
            clienteId: clienteId,
            total: _totalCalculado,
            fecha: _fecha,
            observaciones: _observacionesCtrl.text,
            validezDias: int.tryParse(_validezCtrl.text.trim()) ?? 15,
            detalles: detalles,
          );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cotización CT-${cotizacionId.toString().padLeft(6, '0')} '
            'guardada correctamente.',
          ),
          backgroundColor: Colors.green,
        ),
      );

      if (context.mounted) {
        ref.read(homeTabProvider.notifier).state = 0;
        homeRefreshNotifier.value++;
        Navigator.popUntil(context, (route) => route.isFirst);
      }
    } catch (e) {
      _mostrarError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  void _mostrarError(String mensaje) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    _rucCtrl.dispose();
    _nombreClienteCtrl.dispose();
    _direccionCtrl.dispose();
    _observacionesCtrl.dispose();
    _validezCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Finalizar Cotización',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () async {
                final seleccion = await showDatePicker(
                  context: context,
                  initialDate: _fecha,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  builder: (context, child) => Theme(
                    data: ThemeData.light().copyWith(
                      colorScheme: ColorScheme.light(primary: colorTema),
                    ),
                    child: child!,
                  ),
                );

                if (seleccion != null) {
                  final ahora = AppTime.now();
                  setState(() {
                    _fecha = DateTime(
                      seleccion.year,
                      seleccion.month,
                      seleccion.day,
                      ahora.hour,
                      ahora.minute,
                      ahora.second,
                    );
                  });
                }
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    DateFormat('dd MMM yyyy').format(_fecha),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.calendar_today, size: 18, color: colorTema),
                ],
              ),
            ),
            const SizedBox(height: 15),

            Center(
              child: Column(
                children: [
                  Text(
                    'Total cotizado',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                  Text(
                    'S/ ${NumberFormat('#,##0.00').format(_totalCalculado)}',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      color: colorTema,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 25),

            ResumenItemsCard(
              items: widget.carritoConPreciosFinales,
              titulo: 'Resumen de la Cotización',
              icono: Icons.request_quote_outlined,
            ),
            const SizedBox(height: 25),

            const Text(
              'Datos del Cliente',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 15),
            ClienteAutocompleteField(
              nombreCtrl: _nombreClienteCtrl,
              rucCtrl: _rucCtrl,
              direccionCtrl: _direccionCtrl,
              color: colorTema,
            ),
            const SizedBox(height: 10),
            RucDireccionRow(
              rucCtrl: _rucCtrl,
              direccionCtrl: _direccionCtrl,
              nombreCtrl: _nombreClienteCtrl,
              color: colorTema,
            ),

            const SizedBox(height: 25),
            const Text(
              'Configuración de la Cotización',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Theme.of(context).brightness == Brightness.dark
                    ? null
                    : Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _validezCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: appInputDecoration(
                      'Días de validez',
                      Icons.timelapse_rounded,
                      colorTema,
                      isDark: Theme.of(context).brightness == Brightness.dark,
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _observacionesCtrl,
                    maxLines: 2,
                    decoration: appInputDecoration(
                      'Observaciones o términos',
                      Icons.notes,
                      colorTema,
                      isDark: Theme.of(context).brightness == Brightness.dark,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade900
              : Colors.white,
          boxShadow: Theme.of(context).brightness == Brightness.dark
              ? []
              : const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 10,
                    offset: Offset(0, -5),
                  ),
                ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 55,
            child: ElevatedButton(
              onPressed: _guardando ? null : _procesarCotizacion,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorTema,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                elevation: 5,
              ),
              child: _guardando
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      'GUARDAR COTIZACIÓN',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
