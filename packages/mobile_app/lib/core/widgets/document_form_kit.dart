import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/app_formatters.dart';
import 'package:core_logic/core_logic.dart';
import '../utils/stock_utils.dart';

/// ============================================================
/// KIT COMPARTIDO — VENTAS & COTIZACIONES
/// ============================================================
/// Centraliza todo lo que hoy está duplicado entre
/// DetalleVentaPage y DetalleCotizacionPage:
///  - Colores del "tema" de cada documento
///  - Decoración estándar de inputs
///  - Búsqueda/autocompletado de cliente
///  - Resolución de cliente mediante gateway neutral (vía Riverpod)
///  - Tarjeta de resumen de productos
///  - Row responsive de RUC/Dirección
///
/// ARQUITECTURA: Esta capa de presentación nunca toca el gateway
/// directamente. Todo acceso a datos fluye a través de
/// [documentDataGatewayProvider] (Riverpod), manteniendo el
/// principio de cero acoplamiento de la capa visual.
/// ============================================================

class AppDocColors {
  static Color venta(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
  static final Color cotizacion = Colors.indigo.shade600;
  static const Color credito = Color(0xFFD32F2F);
  static const Color dorado = Color(0xFFF59E0B);
  static const Color naranja = Colors.deepOrange;
}

InputDecoration appInputDecoration(
  String label,
  IconData icon,
  Color color, {
  bool isDark = false,
}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, color: Colors.grey),
    filled: true,
    fillColor: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.grey.shade300,
      ),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.grey.shade300,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: 2),
    ),
    labelStyle: TextStyle(color: isDark ? Colors.grey[400] : null),
    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
  );
}

// ---------------------------------------------------------------------------
// ClienteAutocompleteField
// ---------------------------------------------------------------------------
// ConsumerStatefulWidget: obtiene la lista de clientes a través de
// documentDataGatewayProvider. Sin ClienteService, sin imports de gateway.
// ---------------------------------------------------------------------------

class ClienteAutocompleteField extends ConsumerStatefulWidget {
  final TextEditingController nombreCtrl;
  final TextEditingController rucCtrl;
  final TextEditingController direccionCtrl;
  final Color color;

  const ClienteAutocompleteField({
    super.key,
    required this.nombreCtrl,
    required this.rucCtrl,
    required this.direccionCtrl,
    required this.color,
  });

  @override
  ConsumerState<ClienteAutocompleteField> createState() =>
      _ClienteAutocompleteFieldState();
}

class _ClienteAutocompleteFieldState
    extends ConsumerState<ClienteAutocompleteField> {
  List<Map<String, dynamic>> _todos = [];
  List<Map<String, dynamic>> _sugerencias = [];
  bool _mostrando = false;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _cargar();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) setState(() => _mostrando = false);
        });
      }
    });
  }

  /// Delega la carga de clientes al gateway a través de Riverpod.
  /// La UI nunca llama directamente a ningún servicio de datos.
  Future<void> _cargar() async {
    final gateway = ref.read(documentDataGatewayProvider);
    final data = await gateway.cargarClientes();
    if (mounted) setState(() => _todos = data);
  }

  void _filtrar(String query) {
    if (query.isEmpty) {
      setState(() => _mostrando = false);
      return;
    }
    final q = query.toLowerCase();
    final filtrados = _todos.where((c) {
      final nombre = c['nombre'].toString().toLowerCase();
      final doc = c['dni_ruc'].toString().toLowerCase();
      return nombre.contains(q) || doc.contains(q);
    }).toList();
    setState(() {
      _sugerencias = filtrados;
      _mostrando = filtrados.isNotEmpty;
    });
  }

  void _seleccionar(Map<String, dynamic> c) {
    widget.nombreCtrl.text = c['nombre'];
    widget.rucCtrl.text = c['dni_ruc'] == '00000000' ? '' : c['dni_ruc'];
    widget.direccionCtrl.text = c['direccion'] == '-' ? '' : c['direccion'];
    setState(() => _mostrando = false);
    _focus.unfocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: widget.nombreCtrl,
          focusNode: _focus,
          onChanged: _filtrar,
          decoration: InputDecoration(
            labelText: "Nombre del Cliente",
            floatingLabelStyle: TextStyle(color: widget.color),
            prefixIcon: Icon(
              Icons.person_outline,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[400]
                  : Colors.grey[600],
              size: 20,
            ),
            filled: true,
            fillColor: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.grey.withValues(alpha: 0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.2),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: widget.color, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
        if (_mostrando)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _sugerencias.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final c = _sugerencias[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    c['nombre'],
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("DOC: ${c['dni_ruc']} - ${c['direccion']}"),
                  onTap: () => _seleccionar(c),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// RucDireccionRow
// ---------------------------------------------------------------------------
// ConsumerStatefulWidget: consulta el documento de identidad a través de
// documentDataGatewayProvider. Sin acceso estático al gateway.
// ---------------------------------------------------------------------------

class RucDireccionRow extends ConsumerStatefulWidget {
  final TextEditingController rucCtrl;
  final TextEditingController direccionCtrl;
  final TextEditingController? nombreCtrl;
  final Color color;

  const RucDireccionRow({
    super.key,
    required this.rucCtrl,
    required this.direccionCtrl,
    this.nombreCtrl,
    required this.color,
  });

  @override
  ConsumerState<RucDireccionRow> createState() => _RucDireccionRowState();
}

class _RucDireccionRowState extends ConsumerState<RucDireccionRow> {
  bool _consultando = false;
  String? _estadoSunat;
  String? _condicionSunat;

  /// Delega la consulta SUNAT/RENIEC al gateway a través de Riverpod.
  /// La UI nunca llama directamente a ningún servicio de datos.
  void _consultarDocumento() async {
    final doc = widget.rucCtrl.text.trim();
    if (doc.isEmpty || (doc.length != 8 && doc.length != 11)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El RUC/DNI debe tener 8 o 11 dígitos'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _consultando = true;
      _estadoSunat = null;
      _condicionSunat = null;
    });

    try {
      final tipo = doc.length == 8 ? 'dni' : 'ruc';
      final gateway = ref.read(documentDataGatewayProvider);
      final data = await gateway.consultarPersona(numero: doc, tipo: tipo);

      if (data != null) {
        setState(() {
          if (widget.nombreCtrl != null) {
            if (tipo == 'dni') {
              widget.nombreCtrl!.text = data['nombre_completo'] ?? '';
            } else {
              widget.nombreCtrl!.text = data['razon_social'] ?? '';
            }
          }

          final apiData = data['data'];
          if (apiData != null && apiData is Map) {
            if (apiData['direccion'] != null &&
                apiData['direccion'].toString().trim().isNotEmpty) {
              widget.direccionCtrl.text = apiData['direccion'].toString();
            }
            if (apiData['estado'] != null) {
              _estadoSunat = apiData['estado'].toString();
            }
            if (apiData['condicion'] != null) {
              _condicionSunat = apiData['condicion'].toString();
            }
          }
        });
      }
    } on DocumentLookupException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _consultando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDark = Theme.of(context).brightness == Brightness.dark;

        final rucField = TextField(
          controller: widget.rucCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: "RUC / DNI",
            prefixIcon: const Icon(Icons.badge_outlined, color: Colors.grey),
            suffixIcon: IconButton(
              icon: _consultando
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              color: widget.color,
              tooltip: 'Consultar en SUNAT/RENIEC',
              onPressed: _consultando ? null : _consultarDocumento,
            ),
            filled: true,
            fillColor: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.grey.shade300,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.grey.shade300,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: widget.color, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              vertical: 14,
              horizontal: 16,
            ),
          ),
        );
        final dirField = TextField(
          controller: widget.direccionCtrl,
          decoration: appInputDecoration(
            "Dirección",
            Icons.location_on_outlined,
            widget.color,
            isDark: isDark,
          ),
        );

        final sunatInfo = (_estadoSunat != null || _condicionSunat != null)
            ? Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_estadoSunat != null)
                      Text(
                        'Estado SUNAT: $_estadoSunat',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                    if (_condicionSunat != null)
                      Text(
                        'Condición: $_condicionSunat',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                  ],
                ),
              )
            : const SizedBox.shrink();

        if (constraints.maxWidth > 600) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: rucField),
                  const SizedBox(width: 10),
                  Expanded(child: dirField),
                ],
              ),
              sunatInfo,
            ],
          );
        }
        return Column(
          children: [rucField, const SizedBox(height: 10), dirField, sunatInfo],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// ResumenItemsCard — StatelessWidget puro (sin datos, solo presentación)
// ---------------------------------------------------------------------------

class ResumenItemsCard extends StatelessWidget {
  final SaleCart items;
  final String titulo;
  final IconData icono;

  const ResumenItemsCard({
    super.key,
    required this.items,
    this.titulo = 'Resumen del Pedido',
    this.icono = Icons.shopping_bag_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: isDark ? Theme.of(context).cardColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: Colors.grey[700], size: 20),
              const SizedBox(width: 10),
              Text(
                '$titulo (${items.lineCount})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const Divider(height: 25),
          ...items.lines.map((item) {
            final cantidad = item.quantity;
            final nombre = item.product.name;
            final tipoUnidad = item.product.normalizeUnit(item.commercialUnit);
            final presentation = item.product.commercialProfile.find(
              tipoUnidad,
            );
            final etiqueta =
                presentation?.labelFor(cantidad) ??
                StockUtils.etiquetaUnidadComercial(
                  tipoUnidad,
                  cantidad: cantidad == 1 ? 1 : 2,
                );

            final precioComercial = item.commercialUnitPrice;
            final subtotal = item.subtotal;
            final cantidadTexto = cantidad == cantidad.roundToDouble()
                ? cantidad.toInt().toString()
                : cantidad.toString();

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$cantidadTexto $etiqueta · $nombre',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${AppFormatters.currency(precioComercial)} por '
                          '${presentation?.singularLabel ?? StockUtils.etiquetaUnidadComercial(tipoUnidad, cantidad: 1)}',
                          style: TextStyle(
                            color: isDark
                                ? Colors.grey[400]
                                : Colors.grey.shade600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    AppFormatters.currency(subtotal),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
