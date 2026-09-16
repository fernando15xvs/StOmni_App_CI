import 'package:core_logic/core_logic.dart';
import 'package:core_logic/platform/image_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

// ✅ TUS NUEVOS SERVICIOS Y UTILIDADES
import '../../../core/widgets/almacen_stock_input.dart';
import '../../../core/widgets/app_form_styles.dart';
import 'package:mobile_app/home/home_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/controllers/nuevo_producto_controller.dart';

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

class NuevoProductoPage extends ConsumerStatefulWidget {
  final Map<String, dynamic>? productoEditar;
  const NuevoProductoPage({super.key, this.productoEditar});

  @override
  ConsumerState<NuevoProductoPage> createState() => _NuevoProductoPageState();
}

class _NuevoProductoPageState extends ConsumerState<NuevoProductoPage> {
  bool get _esAdmin => ref.read(rolProvider) == 'admin';

  Color get colorVerde => Theme.of(context).colorScheme.primary;

  final codigoController = TextEditingController();
  final nombreController = TextEditingController();
  final precioUnidadController = TextEditingController();
  final precioCajaController = TextEditingController();
  final precioCompraController = TextEditingController();
  final cantCajaController = TextEditingController();
  final stockMinimoController = TextEditingController();
  final FocusNode _pcsFocusNode = FocusNode();

  final Map<int, TextEditingController> _stockCajasControllers = {};
  final Map<int, TextEditingController> _stockUnidadesControllers = {};
  final Map<int, int> _totalesCalculados = {};

  String? _proveedorSeleccionadoId;
  bool _permitirSinStock = false;
  Uint8List? _imagenNuevaBytes;
  String? _urlImagenExistente;

  SaleUnitType _tipoVenta = SaleUnitType.paquete;

  bool _evaluandoHistorial = false;
  bool _puedeActualizarApertura = false;
  bool _actualizarMovimientosApertura = false;
  int _cantidadMovimientosApertura = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_esAdmin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Solo el administrador puede crear o editar productos.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.of(context).maybePop();
        return;
      }
      ref
          .read(nuevoProductoControllerProvider.notifier)
          .inicializarDatos()
          .then((_) async {
            if (!mounted) return;
            _cargarVariablesUI();
            await _evaluarHistorialDeApertura();
          });
    });

    _pcsFocusNode.addListener(() {
      if (_pcsFocusNode.hasFocus && cantCajaController.text.isNotEmpty) {
        cantCajaController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: cantCajaController.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    codigoController.dispose();
    nombreController.dispose();
    precioUnidadController.dispose();
    precioCajaController.dispose();
    precioCompraController.dispose();
    cantCajaController.dispose();
    stockMinimoController.dispose();
    _pcsFocusNode.dispose();
    for (var c in _stockCajasControllers.values) {
      c.dispose();
    }
    for (var c in _stockUnidadesControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _recalcularTotalesVivo() {
    if (!StockUtils.esMixto(_tipoVenta) || widget.productoEditar != null) {
      return;
    }
    int pcs = int.tryParse(cantCajaController.text) ?? 1;
    if (pcs <= 0) pcs = 1;
    setState(() {
      for (var a in ref.read(nuevoProductoControllerProvider).almacenes) {
        int id = a['id'];
        int cajas = int.tryParse(_stockCajasControllers[id]?.text ?? '0') ?? 0;
        int sueltas =
            int.tryParse(_stockUnidadesControllers[id]?.text ?? '0') ?? 0;
        _totalesCalculados[id] = (cajas * pcs) + sueltas;
      }
    });
  }

  void _recalcularStockPorPCS(int nuevoPcs) {
    if (!StockUtils.esMixto(_tipoVenta)) return;
    for (var a in ref.read(nuevoProductoControllerProvider).almacenes) {
      int id = a['id'];
      int totalActual = _totalesCalculados[id] ?? 0;
      if (totalActual > 0 && nuevoPcs > 0) {
        int nuevasCajas = totalActual ~/ nuevoPcs;
        int nuevasSueltas = totalActual % nuevoPcs;
        _stockCajasControllers[id]?.text = nuevasCajas > 0
            ? nuevasCajas.toString()
            : '';
        _stockUnidadesControllers[id]?.text = nuevasSueltas > 0
            ? nuevasSueltas.toString()
            : '';
      }
    }
    _recalcularTotalesVivo();
  }

  void _cargarVariablesUI() {
    final state = ref.read(nuevoProductoControllerProvider);
    for (var a in state.almacenes) {
      final id = a['id'] as int;
      _stockCajasControllers.putIfAbsent(id, () => TextEditingController());
      _stockUnidadesControllers.putIfAbsent(id, () => TextEditingController());
      _totalesCalculados[id] = 0;
    }

    if (widget.productoEditar != null) {
      final p = widget.productoEditar!;
      codigoController.text = p['codigo']?.toString() ?? '';
      nombreController.text = p['nombre'] ?? '';
      precioUnidadController.text = _formatearNumero(p['precio_unidad']);
      precioCajaController.text =
          (p['precio_caja'] != null && p['precio_caja'] > 0)
          ? _formatearNumero(p['precio_caja'])
          : '';
      precioCompraController.text = _formatearNumero(p['precio_compra']);
      stockMinimoController.text = (p['stock_minimo'] ?? 0).toString();
      _permitirSinStock = p['permitir_sin_stock'] ?? false;

      _tipoVenta = StockUtils.toOfficialType(StockUtils.getTipoVentaFromMap(p));
      int pcsValue = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;

      if (pcsValue > 0) {
        cantCajaController.text = pcsValue.toString();
      }

      if (p['proveedor_id'] != null) {
        final existe = state.proveedores.any(
          (prov) => prov['id'] == p['proveedor_id'],
        );
        if (existe) {
          setState(
            () => _proveedorSeleccionadoId = p['proveedor_id'].toString(),
          );
        }
      }

      if (p['imagen_path'] != null &&
          p['imagen_path'].toString().startsWith('http')) {
        setState(() => _urlImagenExistente = p['imagen_path']);
      }
    }
    _recalcularTotalesVivo();
  }

  Future<void> _evaluarHistorialDeApertura() async {
    final producto = widget.productoEditar;
    final productoId = (producto?['id'] as num?)?.toInt();

    if (productoId == null) return;

    setState(() => _evaluandoHistorial = true);
    try {
      // Delega al controller — la vista nunca accede directamente al repositorio.
      final evaluacion = await ref
          .read(nuevoProductoControllerProvider.notifier)
          .evaluarHistorialApertura(productoId);

      if (!mounted) return;
      final cantidad =
          (evaluacion['movimientos_apertura'] as num?)?.toInt() ?? 0;
      final puedeActualizar =
          evaluacion['puede_actualizar_apertura'] == true && cantidad > 0;

      setState(() {
        _cantidadMovimientosApertura = cantidad;
        _puedeActualizarApertura = puedeActualizar;
        _actualizarMovimientosApertura = puedeActualizar;
      });
    } catch (e) {
      debugPrint('No se pudo evaluar la apertura del producto: $e');
      if (mounted) {
        setState(() {
          _cantidadMovimientosApertura = 0;
          _puedeActualizarApertura = false;
          _actualizarMovimientosApertura = false;
        });
      }
    } finally {
      if (mounted) setState(() => _evaluandoHistorial = false);
    }
  }

  String get _labelPrecioUnidad {
    if (_tipoVenta == SaleUnitType.cajaPaquetes) {
      return 'P. Paquete (S/)';
    }
    return 'P. Unidad (S/)';
  }

  String get _labelPrecioCaja {
    if (_tipoVenta == SaleUnitType.paquete) {
      return 'P. pieza del paquete';
    }
    if (_tipoVenta == SaleUnitType.cajaPaquetes) {
      return 'P. paquete en caja';
    }
    return 'P. unidad en caja';
  }

  String get _labelPcs {
    if (_tipoVenta == SaleUnitType.paquete) {
      return 'Piezas por Paquete (PCS)';
    }
    if (_tipoVenta == SaleUnitType.cajaPaquetes) {
      return 'Paquetes por Caja';
    }
    return 'Unidades por Caja (PCS)';
  }

  String get _labelPrecioCompleto {
    return _tipoVenta == SaleUnitType.paquete
        ? 'Precio paquete completo'
        : 'Precio caja completa';
  }

  String get _unidadBaseTotal {
    return StockUtils.unidadBasePlural(_tipoVenta).toLowerCase();
  }

  double get _precioEmpaqueCompleto {
    final precioBase = _parseDouble(precioCajaController.text);
    final pcs = int.tryParse(cantCajaController.text) ?? 0;
    return StockUtils.calcularPrecioEmpaqueCompleto(
      precioBaseEmpaque: precioBase,
      pcs: pcs,
    );
  }

  String _formatearNumero(dynamic value) {
    if (value == null) return '';
    double numero = value.toDouble();
    if (numero == numero.toInt()) return numero.toInt().toString();
    return numero.toString();
  }

  double _parseDouble(String texto) => double.tryParse(texto) ?? 0.0;
  void _mostrarError(String msg) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  void _mostrarExito(String msg) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.green));

  void _mostrarOpcionesFoto() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.camera_alt, color: colorVerde),
              title: const Text('Tomar foto'),
              onTap: () async {
                Navigator.pop(context);
                await Future.delayed(const Duration(milliseconds: 300));
                await _tomarYRecortarFoto(ImageSelectionSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: colorVerde),
              title: const Text('Galería'),
              onTap: () async {
                Navigator.pop(context);
                await Future.delayed(const Duration(milliseconds: 300));
                await _tomarYRecortarFoto(ImageSelectionSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _tomarYRecortarFoto(ImageSelectionSource source) async {
    try {
      final selected = await ImageSelectionService.select(
        ImageSelectionRequest(
          source: source,
          imageQuality: 85,
          crop: true,
          cropQuality: 85,
        ),
      );
      if (selected == null || !mounted) return;
      setState(() => _imagenNuevaBytes = selected.bytes);
    } catch (e) {
      if (mounted) _mostrarError(ErrorMapper.map(e));
    }
  }

  void _eliminarFoto() => setState(() {
    _imagenNuevaBytes = null;
    _urlImagenExistente = null;
  });

  Future<void> _guardarProducto() async {
    if (!_esAdmin) {
      _mostrarError('Solo el administrador puede crear o editar productos.');
      return;
    }
    FocusScope.of(context).unfocus();

    if (codigoController.text.trim().isEmpty) {
      _mostrarError('El código del producto es obligatorio');
      return;
    }

    if (nombreController.text.trim().isEmpty) {
      _mostrarError('El nombre es obligatorio');
      return;
    }

    final pcs = int.tryParse(cantCajaController.text) ?? 0;
    if (pcs < 1) {
      _mostrarError(
        'Para ventas por caja, la cantidad por empaque debe ser al menos 1.',
      );
      return;
    }

    bool exito = await ref
        .read(nuevoProductoControllerProvider.notifier)
        .guardarProducto(
          productoEditar: widget.productoEditar,
          codigo: codigoController.text.trim(),
          nombre: nombreController.text.trim(),
          precioUnidad: _parseDouble(precioUnidadController.text),
          precioCaja: _parseDouble(precioCajaController.text),
          precioCompra: _parseDouble(precioCompraController.text),
          pcs: int.tryParse(cantCajaController.text) ?? 1,
          tipoVenta: _tipoVenta,
          stockMinimo: int.tryParse(stockMinimoController.text) ?? 0,
          proveedorSeleccionadoId: _proveedorSeleccionadoId,
          permitirSinStock: _permitirSinStock,
          imagenNuevaBytes: _imagenNuevaBytes,
          urlImagenExistente: _urlImagenExistente,
          cajasPorAlmacen: _stockCajasControllers.map(
            (key, value) => MapEntry(key, int.tryParse(value.text) ?? 0),
          ),
          unidadesPorAlmacen: _stockUnidadesControllers.map(
            (key, value) => MapEntry(key, int.tryParse(value.text) ?? 0),
          ),
          actualizarMovimientosApertura:
              _puedeActualizarApertura && _actualizarMovimientosApertura,
        );

    if (exito && mounted) {
      _mostrarExito("Producto guardado correctamente");
      Navigator.pop(context);
      homeRefreshNotifier.value++;
    } else if (mounted) {
      final error = ref.read(nuevoProductoControllerProvider).error;
      if (error != null) _mostrarError(error);
    }
  }

  void _onPcsChanged(String newValue) {
    if (widget.productoEditar != null || !StockUtils.esMixto(_tipoVenta)) {
      _recalcularTotalesVivo();
      return;
    }
    int oldPcs = int.tryParse(cantCajaController.text) ?? 1;
    int newPcs = int.tryParse(newValue) ?? 1;
    if (newPcs <= 0) newPcs = 1;
    if (oldPcs == newPcs) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambiar tamaño de caja'),
        content: Text(
          'Has cambiado "Unidades por caja" de $oldPcs a $newPcs.\n\n¿Deseas recalcular las cajas y sueltas para mantener el total actual?',
        ),
        actions: [
          TextButton(
            onPressed: () {
              _recalcularTotalesVivo();
              Navigator.pop(context);
            },
            child: const Text('NO', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () {
              _recalcularStockPorPCS(newPcs);
              Navigator.pop(context);
            },
            child: const Text('SÍ', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // UI WIDGETS
  // =========================================================================

  InputDecoration _decoracionInput(
    String label,
    IconData icon, {
    String? hint,
  }) {
    return AppFormStyles.inputDecor(
      context,
      label,
      icon: icon,
      primaryColor: colorVerde,
    ).copyWith(hintText: hint);
  }

  Widget _buildImageSection() {
    bool tieneImagen =
        _imagenNuevaBytes != null ||
        (_urlImagenExistente != null && _urlImagenExistente!.isNotEmpty);
    return Center(
      child: Stack(
        children: [
          GestureDetector(
            onTap: _mostrarOpcionesFoto,
            child: Container(
              height: 180,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey.shade800
                      : Colors.grey.shade300,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: _imagenNuevaBytes != null
                    ? Image.memory(_imagenNuevaBytes!, fit: BoxFit.cover)
                    : (_urlImagenExistente != null &&
                          _urlImagenExistente!.isNotEmpty)
                    ? Image.network(_urlImagenExistente!, fit: BoxFit.cover)
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 50,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            "Toca para agregar imagen",
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          Positioned(
            bottom: 10,
            right: 10,
            child: CircleAvatar(
              backgroundColor: colorVerde,
              radius: 20,
              child: const Icon(
                Icons.camera_alt,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          if (tieneImagen)
            Positioned(
              top: 10,
              right: 10,
              child: GestureDetector(
                onTap: _eliminarFoto,
                child: CircleAvatar(
                  backgroundColor: Colors.red.withValues(alpha: 0.9),
                  radius: 15,
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGeneralInfo() {
    return AppFormStyles.buildSeccionCard(
      context,
      titulo: "Información General",
      icono: Icons.info_outline,
      primaryColor: colorVerde,
      contenido: Column(
        children: [
          TextField(
            controller: codigoController,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.characters,
            decoration: _decoracionInput(
              'Código del Producto',
              Icons.qr_code_2,
              hint: 'Ej. FOC-001',
            ),
            inputFormatters: [
              UpperCaseTextFormatter(),
              FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9._/-]')),
              LengthLimitingTextInputFormatter(50),
            ],
          ),
          const SizedBox(height: 15),
          TextField(
            controller: nombreController,
            textInputAction: TextInputAction.next,
            decoration: _decoracionInput('Nombre del Producto', Icons.label),
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
          ),
          const SizedBox(height: 15),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _proveedorSeleccionadoId,
            decoration: _decoracionInput('Marca / Proveedor', Icons.business),
            items: ref
                .watch(
                  nuevoProductoControllerProvider.select((s) => s.proveedores),
                )
                .map(
                  (prov) => DropdownMenuItem<String>(
                    value: prov['id'].toString(),
                    child: Text(
                      prov['nombre'],
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (val) => setState(() => _proveedorSeleccionadoId = val),
          ),
          const SizedBox(height: 15),
          DropdownButtonFormField<SaleUnitType>(
            initialValue: _tipoVenta,
            decoration: _decoracionInput('Tipo de Venta', Icons.sell),
            items: const [
              DropdownMenuItem(
                value: SaleUnitType.paquete,
                child: Text('Paquetes'),
              ),
              DropdownMenuItem(
                value: SaleUnitType.cajaPaquetes,
                child: Text('Caja + Paquetes'),
              ),
              DropdownMenuItem(
                value: SaleUnitType.cajaUnidades,
                child: Text('Caja + Unidades'),
              ),
            ],
            onChanged: (nuevo) {
              if (nuevo != null) {
                setState(() {
                  _tipoVenta = nuevo;

                  // PAQUETES no tiene venta suelta por unidad/paquete
                  // adicional; su precio completo se calcula con precioCaja × PCS.
                  if (_tipoVenta == SaleUnitType.paquete) {
                    precioUnidadController.clear();
                  }

                  for (var c in _stockCajasControllers.values) {
                    c.clear();
                  }
                  for (var c in _stockUnidadesControllers.values) {
                    c.clear();
                  }
                  _recalcularTotalesVivo();
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPreciosYEmpaque() {
    return AppFormStyles.buildSeccionCard(
      context,
      titulo: "Precios y Empaque",
      icono: Icons.attach_money,
      primaryColor: colorVerde,
      contenido: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ✅ MOSTRAR PRECIO UNIDAD SOLO SI ES "UNIDAD" O "AMBOS"
              if (_tipoVenta == SaleUnitType.cajaPaquetes ||
                  _tipoVenta == SaleUnitType.cajaUnidades)
                Expanded(
                  child: TextField(
                    controller: precioUnidadController,
                    textInputAction: TextInputAction.next,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+\.?\d{0,2}'),
                      ),
                    ],
                    decoration: _decoracionInput(
                      _labelPrecioUnidad,
                      Icons.attach_money,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),

              if (_tipoVenta == SaleUnitType.cajaPaquetes ||
                  _tipoVenta == SaleUnitType.cajaUnidades)
                const SizedBox(width: 10),

              // ✅ MOSTRAR PRECIO CAJA SOLO SI ES "CAJA" O "AMBOS"
              if (_tipoVenta == SaleUnitType.paquete ||
                  _tipoVenta == SaleUnitType.cajaPaquetes ||
                  _tipoVenta == SaleUnitType.cajaUnidades)
                Expanded(
                  child: TextField(
                    controller: precioCajaController,
                    textInputAction: TextInputAction.next,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+\.?\d{0,2}'),
                      ),
                    ],
                    decoration: _decoracionInput(
                      _labelPrecioCaja,
                      Icons.inventory_2_outlined,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 15),
          TextField(
            controller: precioCompraController,
            textInputAction: TextInputAction.next,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
            ],
            decoration: _decoracionInput('Costo (S/)', Icons.shopping_cart),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: cantCajaController,
            focusNode: _pcsFocusNode,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.number,
            readOnly: widget.productoEditar != null,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: _decoracionInput(_labelPcs, Icons.apps).copyWith(
              fillColor: widget.productoEditar != null
                  ? (Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[800]
                        : Colors.grey[200])
                  : (Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey.shade900
                        : Colors.white),
            ),
            onChanged: (value) {
              setState(() {});
              if (value.isNotEmpty && int.tryParse(value) == 0) {
                cantCajaController.text = '';
              }
              _onPcsChanged(value);
            },
          ),
          if (_precioEmpaqueCompleto > 0) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.greenAccent.withValues(alpha: 0.08)
                    : colorVerde.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.greenAccent.withValues(alpha: 0.20)
                      : colorVerde.withValues(alpha: 0.20),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _labelPrecioCompleto,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    AppFormatters.currency(_precioEmpaqueCompleto),
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.greenAccent
                          : colorVerde,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConfigAvanzada() {
    return AppFormStyles.buildSeccionCard(
      context,
      titulo: "Configuración Avanzada",
      icono: Icons.settings,
      primaryColor: colorVerde,
      contenido: Column(
        children: [
          SwitchListTile(
            title: const Text(
              "Venta sin Stock",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              "Permitir vender aunque el stock sea 0.",
              style: TextStyle(fontSize: 12),
            ),
            activeThumbColor: Theme.of(context).brightness == Brightness.dark
                ? Colors.greenAccent
                : colorVerde,
            secondary: Icon(
              _permitirSinStock ? Icons.check_circle : Icons.do_not_disturb_on,
              color: _permitirSinStock
                  ? (Theme.of(context).brightness == Brightness.dark
                        ? Colors.greenAccent
                        : colorVerde)
                  : Colors.grey,
            ),
            value: _permitirSinStock,
            onChanged: (val) => setState(() => _permitirSinStock = val),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: stockMinimoController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration:
                  _decoracionInput(
                    'Stock Mínimo (Alerta)',
                    Icons.warning_amber_rounded,
                  ).copyWith(
                    hintText: 'Ej. 5 $_unidadBaseTotal',
                    helperText:
                        'Se calcula en base a $_unidadBaseTotal totales',
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActualizacionAperturaSection() {
    if (widget.productoEditar == null) return const SizedBox.shrink();

    if (_evaluandoHistorial) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text('Revisando el historial inicial del producto...'),
            ),
          ],
        ),
      );
    }

    if (!_puedeActualizarApertura) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
      ),
      child: CheckboxListTile(
        value: _actualizarMovimientosApertura,
        onChanged: (value) {
          setState(() {
            _actualizarMovimientosApertura = value ?? false;
          });
        },
        activeColor: colorVerde,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          'Actualizar también los movimientos de apertura',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          'Este producto aún no tiene operaciones reales. Se corregirán el '
          'nombre, PCS, proveedor y modalidad en '
          '$_cantidadMovimientosApertura '
          '${_cantidadMovimientosApertura == 1 ? 'registro inicial' : 'registros iniciales'}.',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildInventarioSection(bool hayAlmacenes) {
    if (widget.productoEditar != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blue),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Para agregar más stock a este producto, utiliza el nuevo módulo de "Ingreso de Mercadería".',
                style: TextStyle(color: Colors.blue, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return AppFormStyles.buildSeccionCard(
      context,
      titulo: "Stock de Apertura",
      icono: Icons.inventory_2_outlined,
      primaryColor: colorVerde,
      contenido: !hayAlmacenes
          ? Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[900]
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[800]!
                      : Colors.grey[300]!,
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 10),
                  Expanded(child: Text('No hay almacenes activos.')),
                ],
              ),
            )
          : Column(
              children: [
                // ✅ UTILIZACIÓN DEL COMPONENTE REUTILIZABLE
                ...ref
                    .watch(
                      nuevoProductoControllerProvider.select(
                        (s) => s.almacenes,
                      ),
                    )
                    .map((almacen) {
                      int id = almacen['id'];
                      int totalCalculado = _totalesCalculados[id] ?? 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          AlmacenStockInput(
                            nombreAlmacen: almacen['nombre'],
                            tipoVenta: _tipoVenta,
                            cajasController: _stockCajasControllers[id]!,
                            unidadesController: _stockUnidadesControllers[id]!,
                            onChanged: (_) => _recalcularTotalesVivo(),
                          ),
                          if (totalCalculado > 0 &&
                              StockUtils.esMixto(_tipoVenta))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 15),
                              child: Text(
                                "Total inicial: $totalCalculado $_unidadBaseTotal",
                                style: TextStyle(
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.greenAccent
                                      : colorVerde,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      );
                    }),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    "💡 Deja las cantidades en 0 si deseas ingresar el stock más adelante.",
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildGuardarButton(bool hayAlmacenes, bool guardando) {
    return Tooltip(
      message: hayAlmacenes
          ? ''
          : 'Necesitas al menos un almacén activo para guardar',
      child: SizedBox(
        width: double.infinity,
        height: 55,
        child: ElevatedButton(
          onPressed: (!hayAlmacenes || guardando) ? null : _guardarProducto,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorVerde,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 4,
          ),
          child: guardando
              ? const CircularProgressIndicator(color: Colors.white)
              : Text(
                  widget.productoEditar == null
                      ? 'GUARDAR PRODUCTO'
                      : 'ACTUALIZAR PRODUCTO',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(rolProvider) != 'admin') {
      return const Scaffold(
        body: Center(child: Text('Acceso restringido al administrador.')),
      );
    }

    final state = ref.watch(nuevoProductoControllerProvider);

    bool hayAlmacenes = state.almacenes.isNotEmpty;
    bool guardando = state.guardando || _evaluandoHistorial;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.productoEditar == null ? 'Nuevo Producto' : 'Editar Producto',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: colorVerde,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildImageSection(),
                  const SizedBox(height: 25),
                  _buildGeneralInfo(),
                  const SizedBox(height: 25),
                  _buildPreciosYEmpaque(),
                  const SizedBox(height: 25),
                  _buildConfigAvanzada(),
                  if (widget.productoEditar != null) ...[
                    const SizedBox(height: 25),
                    _buildActualizacionAperturaSection(),
                  ],
                  const SizedBox(height: 30),
                  _buildInventarioSection(hayAlmacenes),
                  const SizedBox(height: 25),
                  _buildGuardarButton(hayAlmacenes, guardando),
                ],
              ),
            ),
            if (state.cargando)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(color: colorVerde),
              ),
          ],
        ),
      ),
    );
  }
}
