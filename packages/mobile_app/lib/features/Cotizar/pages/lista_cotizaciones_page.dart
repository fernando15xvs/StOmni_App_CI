import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../ventas/data/ventas_repository.dart';
import '../../ventas/pages/venta_page.dart';
import 'nueva_cotizacion_page.dart';
import 'ver_cotizacion_page.dart';
import 'package:core_logic/core_logic.dart';

class ListaCotizacionesPage extends ConsumerStatefulWidget {
  const ListaCotizacionesPage({super.key});

  @override
  ConsumerState<ListaCotizacionesPage> createState() =>
      _ListaCotizacionesPageState();
}

class _ListaCotizacionesPageState extends ConsumerState<ListaCotizacionesPage> {
  bool _cargando = true;
  String? _errorCarga;
  List<Map<String, dynamic>> _cotizaciones = [];
  final Color colorCotizacion = Colors.indigo.shade600;

  @override
  void initState() {
    super.initState();
    _cargarCotizaciones();
  }

  Future<void> _cargarCotizaciones() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      final data = await ref
          .read(ventasRepositoryProvider)
          .listarCotizaciones();

      if (!mounted) return;

      setState(() {
        _cotizaciones = data;
        _errorCarga = null;
      });
    } catch (e, st) {
      debugPrint('ListaCotizacionesPage: fallo al cargar cotizaciones: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() => _errorCarga = ErrorMapper.map(e));
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _aprobarCotizacion(Map<String, dynamic> cotizacion) async {
    try {
      final carrito = ref
          .read(ventasRepositoryProvider)
          .construirCarritoDesdeCotizacion(cotizacion);

      if (carrito.isEmpty) {
        throw const UserFacingException(
          'La cotización no contiene productos y no puede convertirse en venta.',
        );
      }

      final cliente = cotizacion['clientes'] as Map<String, dynamic>?;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DetalleVentaPage(
            carritoConPreciosFinales: carrito,
            totalAPagar: (cotizacion['total'] as num).toDouble(),
            cotizacionId: (cotizacion['id'] as num).toInt(),
            clientePrellenado: cliente,
          ),
        ),
      );

      await _cargarCotizaciones();
    } catch (e, st) {
      debugPrint('ListaCotizacionesPage: fallo al aprobar cotización: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Color _colorEstado(String estado) {
    switch (estado.toLowerCase()) {
      case 'aprobada':
        return Colors.green;
      case 'vencida':
        return Colors.grey;
      case 'anulada':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 54),
            const SizedBox(height: 16),
            Text(
              _errorCarga ?? 'No se pudieron cargar las cotizaciones.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _cargarCotizaciones,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Cotizaciones',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorCotizacion,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: colorCotizacion))
          : _errorCarga != null
          ? _buildErrorView()
          : _cotizaciones.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.request_quote_outlined,
                    size: 80,
                    color: Colors.grey.shade300,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'No hay cotizaciones registradas',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              color: colorCotizacion,
              onRefresh: _cargarCotizaciones,
              child: ListView.builder(
                padding: const EdgeInsets.only(
                  left: 16,
                  top: 16,
                  right: 16,
                  bottom: 88,
                ),
                itemCount: _cotizaciones.length,
                itemBuilder: (context, index) {
                  final cotizacion = _cotizaciones[index];
                  final estado =
                      cotizacion['estado']?.toString().toLowerCase() ??
                      'pendiente';
                  final pendiente = estado == 'pendiente';
                  final colorEstado = _colorEstado(estado);
                  final codigo =
                      'CT-${cotizacion['id'].toString().padLeft(6, '0')}';
                  final detalles =
                      cotizacion['detalle_cotizaciones'] as List? ?? const [];

                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    elevation: 0,
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VerCotizacionPage(
                              cotizacionId: (cotizacion['id'] as num).toInt(),
                            ),
                          ),
                        );

                        if (result == true) {
                          await _cargarCotizaciones();
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow:
                              Theme.of(context).brightness == Brightness.dark
                              ? []
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                          border:
                              Theme.of(context).brightness == Brightness.dark
                              ? null
                              : Border.all(color: Colors.grey.shade200),
                        ),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  codigo,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorEstado.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: colorEstado.withValues(
                                        alpha: 0.35,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    estado.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: colorEstado,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Icon(
                                  Icons.person,
                                  size: 16,
                                  color: Colors.grey.shade500,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    cotizacion['clientes']?['nombre']
                                            ?.toString() ??
                                        'Cliente General',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  Icons.calendar_today,
                                  size: 16,
                                  color: Colors.grey.shade500,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  AppFormatters.limaDateTimeText(
                                    cotizacion['fecha'],
                                  ),
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${detalles.length} ${detalles.length == 1 ? 'presentación' : 'presentaciones'}',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 12,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: Divider(),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'S/ ${NumberFormat('#,##0.00').format((cotizacion['total'] as num).toDouble())}',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.indigo.shade300
                                        : colorCotizacion,
                                  ),
                                ),
                                if (pendiente)
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: colorCotizacion,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    onPressed: () =>
                                        _aprobarCotizacion(cotizacion),
                                    icon: const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                    label: const Text(
                                      'APROBAR',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NuevaCotizacionPage()),
          );
          await _cargarCotizaciones();
        },
        backgroundColor: colorCotizacion,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'NUEVA COTIZACIÓN',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
