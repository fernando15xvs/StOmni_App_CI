import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/almacen/data/product_unit_configuration_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../core/widgets/almacen_stock_input.dart';
import '../../proveedores/data/proveedores_repository.dart';
import '../../shared/widgets/product_search_widget.dart';
import '../presentation/controllers/ingreso_mercaderia_controller.dart';

class IngresoMercaderiaPage extends ConsumerStatefulWidget {
  const IngresoMercaderiaPage({super.key});

  @override
  ConsumerState<IngresoMercaderiaPage> createState() =>
      _IngresoMercaderiaPageState();
}

class _IngresoMercaderiaPageState extends ConsumerState<IngresoMercaderiaPage> {
  final _documentoCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final Map<int, TextEditingController> _cajasCtrls = {};
  final Map<int, TextEditingController> _unidadesCtrls = {};

  Map<String, dynamic>? _producto;
  List<Map<String, dynamic>> _almacenes = const [];
  List<Map<String, dynamic>> _proveedores = const [];
  int? _proveedorId;
  DateTime _fecha = AppTime.now();
  String _tipo = 'Compra';
  String _requestId = const Uuid().v4();
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargarDatos();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(ingresoMercaderiaNotifierProvider, (previous, next) {
        if (!mounted) return;
        if (next.exito) {
          ref.read(ingresoMercaderiaNotifierProvider.notifier).limpiarExito();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Ingreso registrado correctamente.'),
              backgroundColor: Colors.green,
            ),
          );
          _limpiarOperacion();
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
    _documentoCtrl.dispose();
    _observacionesCtrl.dispose();
    for (final controller in _cajasCtrls.values) {
      controller.dispose();
    }
    for (final controller in _unidadesCtrls.values) {
      controller.dispose();
    }
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

  Future<void> _cargarDatos() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }
    try {
      final result = await Future.wait<dynamic>([
        ref.read(almacenRepositoryProvider).obtenerAlmacenesDirecto(),
        ref.read(proveedoresRepositoryProvider).obtenerProveedoresActivos(),
      ]);
      if (!mounted) return;
      final warehouses = List<Map<String, dynamic>>.from(result[0] as List);
      final suppliers = List<Map<String, dynamic>>.from(result[1] as List);
      for (final controller in _cajasCtrls.values) {
        controller.dispose();
      }
      for (final controller in _unidadesCtrls.values) {
        controller.dispose();
      }
      _cajasCtrls.clear();
      _unidadesCtrls.clear();
      for (final warehouse in warehouses) {
        final id = (warehouse['id'] as num).toInt();
        _cajasCtrls[id] = TextEditingController();
        _unidadesCtrls[id] = TextEditingController();
      }
      setState(() {
        _almacenes = warehouses;
        _proveedores = suppliers;
        _cargando = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _errorCarga = ErrorMapper.map(error);
      });
    }
  }

  void _seleccionarProducto(Map<String, dynamic> product) {
    final supplier = (product['proveedor_id'] as num?)?.toInt();
    setState(() {
      _producto = product;
      _proveedorId =
          supplier != null &&
              _proveedores.any(
                (row) => (row['id'] as num?)?.toInt() == supplier,
              )
          ? supplier
          : null;
      _limpiarCantidades();
    });
  }

  void _limpiarCantidades() {
    for (final controller in _cajasCtrls.values) {
      controller.clear();
    }
    for (final controller in _unidadesCtrls.values) {
      controller.clear();
    }
  }

  void _limpiarOperacion() {
    setState(() {
      _producto = null;
      _proveedorId = null;
      _fecha = AppTime.now();
      _tipo = 'Compra';
      _documentoCtrl.clear();
      _observacionesCtrl.clear();
      _limpiarCantidades();
      _requestId = const Uuid().v4();
    });
  }

  DateTime _fechaConHoraActual() {
    final now = AppTime.now();
    return DateTime(
      _fecha.year,
      _fecha.month,
      _fecha.day,
      now.hour,
      now.minute,
      now.second,
    );
  }

  Future<void> _seleccionarFecha() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(2020),
      lastDate: AppTime.now(),
    );
    if (value != null && mounted) setState(() => _fecha = value);
  }

  List<Map<String, dynamic>> _allocations() {
    final product = _producto!;
    final config = _configuration(product);
    final result = <Map<String, dynamic>>[];
    final tipo = StockUtils.getTipoVentaFromMap(product);
    final pcs = (product['cantidad_por_caja'] as num?)?.toInt() ?? 1;

    for (final warehouse in _almacenes) {
      final id = (warehouse['id'] as num).toInt();
      late final double baseQuantity;
      if (config != null) {
        final parsed = double.tryParse(
          (_unidadesCtrls[id]?.text ?? '').trim().replaceAll(',', '.'),
        );
        if (parsed == null || !parsed.isFinite || parsed <= 0) continue;
        try {
          config.toStoredBaseQuantity(parsed);
        } catch (_) {
          throw StateError(
            'La cantidad de ${warehouse['nombre']} excede la precisión configurada.',
          );
        }
        baseQuantity = parsed;
      } else {
        final boxes = int.tryParse(_cajasCtrls[id]?.text.trim() ?? '') ?? 0;
        final units = int.tryParse(_unidadesCtrls[id]?.text.trim() ?? '') ?? 0;
        if (boxes <= 0 && units <= 0) continue;
        baseQuantity = StockUtils.calcularTotalPiezas(
          cajas: boxes,
          unidades: units,
          tipoVenta: tipo,
          pcs: pcs,
        ).toDouble();
      }
      if (baseQuantity > 0) {
        result.add({'almacen_id': id, 'cantidad_base': baseQuantity});
      }
    }
    return result;
  }

  Future<void> _guardar() async {
    final product = _producto;
    if (product == null) return;
    List<Map<String, dynamic>> allocations;
    try {
      allocations = _allocations();
    } catch (error) {
      _mensaje(ErrorMapper.map(error));
      return;
    }
    if (allocations.isEmpty) {
      _mensaje('Ingresa una cantidad válida en al menos un almacén.');
      return;
    }

    final pcs = (product['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final unitPrice = (product['precio_unidad'] as num?)?.toDouble() ?? 0;
    final boxBasePrice = (product['precio_caja'] as num?)?.toDouble() ?? 0;
    final completeBoxPrice = boxBasePrice > 0
        ? boxBasePrice * pcs
        : unitPrice * pcs;

    await ref
        .read(ingresoMercaderiaNotifierProvider.notifier)
        .registrar(
          requestId: _requestId,
          productoId: (product['id'] as num).toInt(),
          fecha: _fechaConHoraActual(),
          tipoIngreso: _tipo,
          documento: _documentoCtrl.text.trim(),
          proveedorId: _proveedorId,
          observaciones: _observacionesCtrl.text.trim(),
          almacenes: allocations,
          ingresoCosto: (product['precio_compra'] as num?)?.toDouble() ?? 0,
          ingresoPUnit: unitPrice,
          ingresoPCaja: boxBasePrice,
          ingresoPCComp: completeBoxPrice,
        );
  }

  void _mensaje(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ingresoMercaderiaNotifierProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Ingreso de mercadería')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _errorCarga != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorCarga!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _cargarDatos,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : _producto == null
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
          : _form(state),
    );
  }

  Widget _form(IngresoMercaderiaState state) {
    final product = _producto!;
    final config = _configuration(product);
    final base = config?.profile.baseUnit;
    final tipo = StockUtils.getTipoVentaFromMap(product);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            product['nombre']?.toString() ?? 'Producto',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            base == null
                ? StockUtils.displayName(tipo)
                : 'Stock base: ${base.pluralLabel} · precisión ${base.quantityPrecision}',
          ),
          trailing: TextButton(
            onPressed: state.guardando ? null : _limpiarOperacion,
            child: const Text('Cambiar'),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _tipo,
          decoration: const InputDecoration(
            labelText: 'Tipo de ingreso',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'Compra', child: Text('Compra')),
            DropdownMenuItem(
              value: 'Ajuste de Inventario',
              child: Text('Ajuste de inventario'),
            ),
          ],
          onChanged: state.guardando
              ? null
              : (value) => setState(() => _tipo = value ?? _tipo),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int?>(
          initialValue: _proveedorId,
          decoration: const InputDecoration(
            labelText: 'Proveedor',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Sin proveedor'),
            ),
            ..._proveedores.map(
              (row) => DropdownMenuItem<int?>(
                value: (row['id'] as num).toInt(),
                child: Text(row['nombre']?.toString() ?? 'Proveedor'),
              ),
            ),
          ],
          onChanged: state.guardando
              ? null
              : (value) => setState(() => _proveedorId = value),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text('Fecha: ${DateFormat('dd/MM/yyyy').format(_fecha)}'),
            ),
            TextButton.icon(
              onPressed: state.guardando ? null : _seleccionarFecha,
              icon: const Icon(Icons.calendar_today),
              label: const Text('Cambiar'),
            ),
          ],
        ),
        TextField(
          controller: _documentoCtrl,
          enabled: !state.guardando,
          decoration: const InputDecoration(
            labelText: 'Documento / factura (opcional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Distribución por almacén',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        ..._almacenes.map((warehouse) {
          final id = (warehouse['id'] as num).toInt();
          return AlmacenStockInput(
            nombreAlmacen: warehouse['nombre']?.toString() ?? 'Almacén',
            tipoVenta: tipo,
            cajasController: _cajasCtrls[id]!,
            unidadesController: _unidadesCtrls[id]!,
            configuredBaseMode: config != null,
            baseQuantityPrecision: base?.quantityPrecision ?? 0,
            baseQuantityLabel: base?.pluralLabel,
          );
        }),
        TextField(
          controller: _observacionesCtrl,
          enabled: !state.guardando,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Observaciones',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: state.guardando ? null : _guardar,
          icon: state.guardando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: Text(state.guardando ? 'Guardando...' : 'Registrar ingreso'),
        ),
      ],
    );
  }
}
