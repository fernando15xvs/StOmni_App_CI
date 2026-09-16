import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/almacen/data/product_unit_configuration_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../facturacion/pages/nueva_guia_remision_page.dart';
import '../../shared/widgets/product_search_widget.dart';
import '../presentation/controllers/mover_stock_controller.dart';

class MoverStockPage extends ConsumerStatefulWidget {
  const MoverStockPage({super.key});

  @override
  ConsumerState<MoverStockPage> createState() => _MoverStockPageState();
}

class _MoverStockPageState extends ConsumerState<MoverStockPage> {
  final _cantidadCtrl = TextEditingController();
  final _cajasCtrl = TextEditingController();
  final _unidadesCtrl = TextEditingController();
  final _motivoCtrl = TextEditingController();

  Map<String, dynamic>? _producto;
  List<Map<String, dynamic>> _almacenes = const [];
  int? _origenId;
  int? _destinoId;
  bool _merma = false;
  bool _cargando = true;
  String _requestId = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    _cargarAlmacenes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(moverStockNotifierProvider, (previous, next) async {
        if (!mounted) return;
        if (next.exito != null) {
          final result = next.exito!;
          ref.read(moverStockNotifierProvider.notifier).limpiarExito();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.esTraslado
                    ? 'Traslado registrado correctamente.'
                    : 'Merma registrada correctamente.',
              ),
              backgroundColor: Colors.green,
            ),
          );
          final transferenciaId = result.transferenciaId;
          _limpiarOperacion();
          await _cargarAlmacenes();
          if (result.esTraslado && transferenciaId != null && mounted) {
            await _preguntarCrearGuia(transferenciaId);
          }
        } else if (next.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(next.error!), backgroundColor: Colors.red),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _cantidadCtrl.dispose();
    _cajasCtrl.dispose();
    _unidadesCtrl.dispose();
    _motivoCtrl.dispose();
    super.dispose();
  }

  ProductUnitConfiguration? _configuration(Map<String, dynamic>? product) {
    if (product == null) return null;
    try {
      return ProductUnitConfigurationMapper.decodeNullable(
        product['unit_configuration'],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _cargarAlmacenes() async {
    try {
      final rows = await ref
          .read(almacenRepositoryProvider)
          .obtenerAlmacenesDirecto();
      if (!mounted) return;
      final data = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _almacenes = data;
        final ids = data.map((e) => (e['id'] as num).toInt()).toList();
        if (_origenId == null || !ids.contains(_origenId)) {
          _origenId = ids.isEmpty ? null : ids.first;
        }
        if (_destinoId == null ||
            !ids.contains(_destinoId) ||
            _destinoId == _origenId) {
          _destinoId = ids.where((id) => id != _origenId).firstOrNull;
        }
        _cargando = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _cargando = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
    }
  }

  void _seleccionarProducto(Map<String, dynamic> product) {
    setState(() {
      _producto = product;
      _cantidadCtrl.clear();
      _cajasCtrl.clear();
      _unidadesCtrl.clear();
      _motivoCtrl.clear();
    });
  }

  void _limpiarOperacion() {
    setState(() {
      _producto = null;
      _cantidadCtrl.clear();
      _cajasCtrl.clear();
      _unidadesCtrl.clear();
      _motivoCtrl.clear();
      _requestId = const Uuid().v4();
    });
  }

  double _stockActual(int almacenId) {
    final inventory = _producto?['inventario_almacen'];
    if (inventory is! List) return 0;
    for (final raw in inventory) {
      if (raw is Map && (raw['almacen_id'] as num?)?.toInt() == almacenId) {
        return (raw['cantidad'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }

  String _stockText(double value) {
    final config = _configuration(_producto);
    if (config != null) {
      final precision = config.profile.baseUnit.quantityPrecision;
      final label = value == 1
          ? config.profile.baseUnit.singularLabel
          : config.profile.baseUnit.pluralLabel;
      return '${value.toStringAsFixed(precision)} $label';
    }
    final tipo = StockUtils.getTipoVentaFromMap(_producto!);
    final pcs = (_producto!['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    return StockUtils.formatStock(value.round(), pcs, tipo);
  }

  double? _cantidadBase() {
    final product = _producto;
    if (product == null) return null;
    final config = _configuration(product);
    if (config != null) {
      final value = double.tryParse(
        _cantidadCtrl.text.trim().replaceAll(',', '.'),
      );
      if (value == null || !value.isFinite || value <= 0) return null;
      try {
        config.toStoredBaseQuantity(value);
        return value;
      } catch (_) {
        return null;
      }
    }

    final cajas = int.tryParse(_cajasCtrl.text.trim()) ?? 0;
    final unidades = int.tryParse(_unidadesCtrl.text.trim()) ?? 0;
    if (cajas <= 0 && unidades <= 0) return null;
    final tipo = StockUtils.getTipoVentaFromMap(product);
    final pcs = (product['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    return StockUtils.calcularTotalPiezas(
      cajas: cajas,
      unidades: unidades,
      tipoVenta: tipo,
      pcs: pcs,
    ).toDouble();
  }

  Future<void> _registrar() async {
    final product = _producto;
    final origen = _origenId;
    if (product == null || origen == null) return;
    if (!_merma && (_destinoId == null || _destinoId == origen)) {
      _mensaje('Selecciona un almacén de destino diferente.');
      return;
    }
    if (_merma && _motivoCtrl.text.trim().isEmpty) {
      _mensaje('Indica el motivo de la merma.');
      return;
    }
    final quantity = _cantidadBase();
    if (quantity == null) {
      _mensaje('Ingresa una cantidad válida.');
      return;
    }
    final stock = _stockActual(origen);
    if (quantity - stock > 0.000001) {
      _mensaje('Stock insuficiente. Disponible: ${_stockText(stock)}.');
      return;
    }

    await ref
        .read(moverStockNotifierProvider.notifier)
        .registrarMovimiento(
          requestId: _requestId,
          productoId: (product['id'] as num).toInt(),
          cantidad: quantity,
          origenId: origen,
          destinoId: _merma ? null : _destinoId,
          esMerma: _merma,
          motivo: _motivoCtrl.text.trim(),
        );
  }

  void _mensaje(String value) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(value), backgroundColor: Colors.red));
  }

  Future<void> _preguntarCrearGuia(int transferenciaId) async {
    final create = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Traslado registrado'),
        content: const Text(
          '¿Deseas crear ahora la guía de remisión de este traslado?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Más tarde'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Crear guía'),
          ),
        ],
      ),
    );
    if (create == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              NuevaGuiaRemisionPage(transferenciaId: transferenciaId),
        ),
      );
    }
  }

  Widget _cantidadFields() {
    final config = _configuration(_producto);
    if (config != null) {
      final base = config.profile.baseUnit;
      final precision = base.quantityPrecision;
      return TextField(
        controller: _cantidadCtrl,
        keyboardType: TextInputType.numberWithOptions(decimal: precision > 0),
        inputFormatters: [
          TextInputFormatter.withFunction((oldValue, newValue) {
            final text = newValue.text.replaceAll(',', '.');
            final regex = RegExp('^\\d*(?:\\.\\d{0,$precision})?\$');
            if (!regex.hasMatch(text)) return oldValue;
            return newValue.copyWith(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
          }),
        ],
        decoration: InputDecoration(
          labelText: 'Cantidad en ${base.pluralLabel}',
          prefixIcon: const Icon(Icons.scale_outlined),
          border: const OutlineInputBorder(),
        ),
      );
    }

    final tipo = StockUtils.getTipoVentaFromMap(_producto!);
    final mixto = StockUtils.esMixto(tipo);
    final paquetes = StockUtils.usaPaquetesComoBase(tipo);
    return Row(
      children: [
        if (mixto) ...[
          Expanded(
            child: TextField(
              controller: _cajasCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Cajas',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: TextField(
            controller: _unidadesCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: paquetes ? 'Paquetes' : 'Unidades',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(moverStockNotifierProvider);
    if (_cargando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Mover stock / mermas')),
      body: _producto == null
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: ProductSearchWidget(
                onSearch: (query) => ref
                    .read(almacenRepositoryProvider)
                    .buscarProductosRapido(query, incluirInactivos: false),
                primaryColor: Theme.of(context).colorScheme.primary,
                onProductoSelected: _seleccionarProducto,
                autofocus: false,
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _producto!['nombre']?.toString() ?? 'Producto',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    _configuration(_producto) == null
                        ? StockUtils.displayName(
                            StockUtils.getTipoVentaFromMap(_producto!),
                          )
                        : 'Inventario en ${_configuration(_producto)!.profile.baseUnit.pluralLabel}',
                  ),
                  trailing: TextButton(
                    onPressed: state.guardando ? null : _limpiarOperacion,
                    child: const Text('Cambiar'),
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Traslado')),
                    ButtonSegment(value: true, label: Text('Merma')),
                  ],
                  selected: {_merma},
                  onSelectionChanged: state.guardando
                      ? null
                      : (value) => setState(() => _merma = value.first),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<int>(
                  initialValue: _origenId,
                  decoration: InputDecoration(
                    labelText: _merma
                        ? 'Almacén a descontar'
                        : 'Almacén origen',
                    border: const OutlineInputBorder(),
                  ),
                  items: _almacenes
                      .map(
                        (row) => DropdownMenuItem<int>(
                          value: (row['id'] as num).toInt(),
                          child: Text(row['nombre']?.toString() ?? 'Almacén'),
                        ),
                      )
                      .toList(),
                  onChanged: state.guardando
                      ? null
                      : (value) => setState(() {
                          _origenId = value;
                          if (_destinoId == value) {
                            _destinoId = _almacenes
                                .map((e) => (e['id'] as num).toInt())
                                .where((id) => id != value)
                                .firstOrNull;
                          }
                        }),
                ),
                if (_origenId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Disponible: ${_stockText(_stockActual(_origenId!))}',
                    ),
                  ),
                if (!_merma) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: _destinoId,
                    decoration: const InputDecoration(
                      labelText: 'Almacén destino',
                      border: OutlineInputBorder(),
                    ),
                    items: _almacenes
                        .where((row) => (row['id'] as num).toInt() != _origenId)
                        .map(
                          (row) => DropdownMenuItem<int>(
                            value: (row['id'] as num).toInt(),
                            child: Text(row['nombre']?.toString() ?? 'Almacén'),
                          ),
                        )
                        .toList(),
                    onChanged: state.guardando
                        ? null
                        : (value) => setState(() => _destinoId = value),
                  ),
                ],
                const SizedBox(height: 20),
                _cantidadFields(),
                const SizedBox(height: 16),
                TextField(
                  controller: _motivoCtrl,
                  enabled: !state.guardando,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: _merma
                        ? 'Motivo de la merma'
                        : 'Motivo (opcional)',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: state.guardando ? null : _registrar,
                  icon: state.guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _merma ? Icons.delete_sweep : Icons.local_shipping,
                        ),
                  label: Text(
                    state.guardando
                        ? 'Procesando...'
                        : _merma
                        ? 'Registrar merma'
                        : 'Confirmar traslado',
                  ),
                ),
              ],
            ),
    );
  }
}
