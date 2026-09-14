import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../presentation/controllers/gre_submission_coordinator.dart';
import '../presentation/state/gre_form_model.dart';
import '../widgets/nueva_guia/gre_documento_section.dart';
import '../widgets/nueva_guia/gre_form_actions.dart';
import '../widgets/nueva_guia/gre_peso_section.dart';
import '../widgets/nueva_guia/gre_producto_editor_dialog.dart';
import '../widgets/nueva_guia/gre_productos_section.dart';
import '../widgets/nueva_guia/gre_ruta_section.dart';
import '../widgets/nueva_guia/gre_transporte_section.dart';
import 'ver_guia_remision_page.dart';
import '../../ventas/pages/seleccion_productos_page.dart';
import '../../ventas/presentation/controllers/carrito_controller.dart';

class NuevaGuiaRemisionPage extends ConsumerStatefulWidget {
  final int? ventaId;
  final int? transferenciaId;
  final String? guiaId;

  const NuevaGuiaRemisionPage({
    super.key,
    this.ventaId,
    this.transferenciaId,
    this.guiaId,
  });

  @override
  ConsumerState<NuevaGuiaRemisionPage> createState() =>
      _NuevaGuiaRemisionPageState();
}

class _NuevaGuiaRemisionPageState extends ConsumerState<NuevaGuiaRemisionPage> {
  static const _motivos = <String, String>{
    '01': 'VENTA',
    '02': 'COMPRA',
    '04': 'TRASLADO ENTRE ESTABLECIMIENTOS DE LA MISMA EMPRESA',
    '08': 'IMPORTACIÓN',
    '09': 'EXPORTACIÓN',
    '13': 'OTROS',
    '14': 'VENTA SUJETA A CONFIRMACIÓN DEL COMPRADOR',
    '18': 'TRASLADO POR EMISOR ITINERANTE',
    '19': 'TRASLADO A ZONA PRIMARIA',
  };

  final GreFormModel _form = GreFormModel();
  bool _cargando = true;
  bool _guardando = false;
  bool _consultandoDestinatario = false;

  Color get _color => Colors.deepPurple;
  bool get _esEdicion => _form.esEdicion(widget.guiaId);

  @override
  void initState() {
    super.initState();
    _form.destDocCtrl.addListener(_actualizarTipoDestinatario);
    _cargar();
  }

  @override
  void dispose() {
    _form.destDocCtrl.removeListener(_actualizarTipoDestinatario);
    _form.dispose();
    super.dispose();
  }

  void _actualizarTipoDestinatario() {
    final anterior = _form.destTipo;
    _form.actualizarTipoDestinatarioDesdeDocumento();
    if (mounted && anterior != _form.destTipo) setState(() {});
  }

  Future<void> _cargar() async {
    try {
      final data = await ref
          .read(guiasRemisionRepositoryProvider)
          .cargarBase(
            ventaId: widget.ventaId,
            transferenciaId: widget.transferenciaId,
            guiaId: widget.guiaId,
          );
      _form.cargarDesdeBase(data);

      if (!mounted) return;
      setState(() => _cargando = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargando = false);
      _error('No se pudo preparar la guía: $e');
    }
  }

  Future<void> _consultarDestinatario() async {
    final doc = _form.destDocCtrl.text.trim();
    if (doc.isEmpty) {
      _error('Ingresa un DNI o RUC para buscar.');
      return;
    }

    final direccionAnterior = _form.destDireccionCtrl.text.trim();
    final ubigeoAnterior = _form.destUbigeoCtrl.text.trim();

    setState(() => _consultandoDestinatario = true);
    try {
      final data = await ref
          .read(greDestinatarioServiceProvider)
          .consultar(doc);
      if (data == null || !mounted) return;

      final actualizarLlegada = GreDestinatarioPolicy.debeActualizarLlegada(
        direccionDestinatarioAnterior: direccionAnterior,
        ubigeoDestinatarioAnterior: ubigeoAnterior,
        direccionLlegadaActual: _form.llegadaDireccionCtrl.text,
        ubigeoLlegadaActual: _form.llegadaUbigeoCtrl.text,
        usaAgenciaDestino:
            (_form.indTransbordo && _form.destinoEntregaTipo == 'agencia') ||
            _form.agenciaDestinoId != null,
      );

      setState(() {
        _form.destTipo = data.tipoDocumentoSunat;
        _form.destNombreCtrl.text = data.nombre;
        _form.destDireccionCtrl.text = data.direccion;
        _form.destUbigeoCtrl.text = data.ubigeo;

        if (actualizarLlegada) {
          _form.llegadaDireccionCtrl.text = data.direccion;
          _form.llegadaUbigeoCtrl.text = data.ubigeo;
        }
      });
    } on FormatException catch (e) {
      _error(e.message);
    } catch (_) {
      _error('No se encontró el documento en SUNAT/RENIEC.');
    } finally {
      if (mounted) setState(() => _consultandoDestinatario = false);
    }
  }

  Future<void> _agregarProductoManual() async {
    ref.read(carritoProvider.notifier).limpiarCarrito();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeleccionProductosV2(
          onContinuarFlow: (ctx, carritoFinal, total) {
            Navigator.pop(ctx);
            Navigator.pop(context);

            Future.microtask(() {
              if (!mounted) return;
              try {
                final nuevasLineas = GreItemMapper.desdeCarrito(
                  SaleCartMapper.encode(carritoFinal),
                  almacenFallback: _form.almacenPartidaId,
                );
                setState(() {
                  _form.detalles.addAll(nuevasLineas);
                  _form.recalcularPeso();
                });
              } on FormatException catch (e) {
                _error(e.message);
              } on ArgumentError catch (e) {
                _error(e.message?.toString() ?? e.toString());
              } catch (e) {
                _error('No se pudieron agregar los productos: $e');
              } finally {
                ref.read(carritoProvider.notifier).limpiarCarrito();
              }
            });
          },
        ),
      ),
    );
  }

  Future<void> _editarLinea(int index) async {
    final item = _form.detalles[index];
    final productoRaw = item['producto_data'];
    final producto = productoRaw is Map
        ? Map<String, dynamic>.from(productoRaw)
        : _form.productoPorId(item['producto_id']);

    final resultado = await mostrarGreProductoEditor(
      context: context,
      item: item,
      producto: producto,
    );
    if (resultado == null || !mounted) return;

    setState(() {
      resultado.aplicarA(item);
      _form.recalcularPeso();
    });
  }

  Future<void> _elegirFechaTraslado() async {
    final actual = _form.fechaTraslado;
    final ahora = AppTime.now();
    final primeraFecha = DateTime(
      ahora.year,
      ahora.month,
      ahora.day,
    ).subtract(const Duration(days: 7));
    final ultimaFecha = DateTime(
      ahora.year,
      ahora.month,
      ahora.day,
    ).add(const Duration(days: 365));
    final fechaActual = DateTime(actual.year, actual.month, actual.day);
    final fechaInicial = fechaActual.isBefore(primeraFecha)
        ? primeraFecha
        : fechaActual.isAfter(ultimaFecha)
            ? ultimaFecha
            : fechaActual;

    final fecha = await showDatePicker(
      context: context,
      initialDate: fechaInicial,
      firstDate: primeraFecha,
      lastDate: ultimaFecha,
      helpText: 'Selecciona la fecha del traslado',
      cancelText: 'CANCELAR',
      confirmText: 'SIGUIENTE',
    );
    if (fecha == null || !mounted) return;

    final hora = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: actual.hour, minute: actual.minute),
      helpText: 'Hora de inicio del traslado',
      cancelText: 'CANCELAR',
      confirmText: 'ACEPTAR',
    );
    if (hora == null || !mounted) return;

    setState(() {
      _form.fechaTraslado = DateTime(
        fecha.year,
        fecha.month,
        fecha.day,
        hora.hour,
        hora.minute,
      );
    });
  }

  void _cambiarTipoGuia(String value) {
    setState(() {
      _form.tipoGuia = value;
      if (value == 'transportista') {
        _form.modalidad = '01';
        _form.transportistaId = null;
        _form.indTransbordo = false;
        _form.transportistaTransbordoId = null;
        _form.agenciaOrigenId = null;
        _form.agenciaDestinoId = null;
      }
    });
  }

  void _cambiarFlujoTransporte(String value) {
    setState(() {
      if (value == 'publico') {
        _form.modalidad = '01';
        _form.indTransbordo = false;
        _form.conductorId = null;
        _form.vehiculoId = null;
        _form.transportistaTransbordoId = null;
        _form.agenciaOrigenId = null;
        _form.agenciaDestinoId = null;
      } else if (value == 'transbordo') {
        _form.modalidad = '02';
        _form.indTransbordo = true;
        _form.transportistaId = null;
        _form.destinoEntregaTipo = 'agencia';
      } else {
        _form.modalidad = '02';
        _form.indTransbordo = false;
        _form.transportistaId = null;
        _form.transportistaTransbordoId = null;
        _form.agenciaOrigenId = null;
        _form.agenciaDestinoId = null;
      }
    });
  }

  void _cambiarTransportistaTransbordo(int? value) {
    setState(() {
      _form.transportistaTransbordoId = value;
      _form.agenciaOrigenId = null;
      _form.agenciaDestinoId = null;
      _form.llegadaDireccionCtrl.clear();
      _form.llegadaUbigeoCtrl.clear();
    });
  }

  void _cambiarDestinoEntregaTipo(String value) {
    setState(() {
      _form.destinoEntregaTipo = value;
      if (value == 'agencia') {
        _form.agenciaDestinoId = null;
        _form.llegadaDireccionCtrl.clear();
        _form.llegadaUbigeoCtrl.clear();
      } else {
        _form.usarDireccionClienteComoLlegada();
      }
    });
  }

  Future<void> _guardar({required bool emitir}) async {
    if (_guardando) return;

    late final GrePreparedSubmission prepared;
    try {
      prepared = GreSubmissionCoordinator.preparar(
        form: _form,
        emitir: emitir,
        motivos: _motivos,
        guiaId: widget.guiaId,
        ventaId: widget.ventaId,
        transferenciaId: widget.transferenciaId,
      );
    } on FormatException catch (e) {
      _error(e.message);
      return;
    }

    setState(() => _guardando = true);
    try {
      final guiaId = await prepared.guardar(
        ref.read(guiasRemisionRepositoryProvider),
      );

      if (emitir) {
        try {
          await FacturacionService.emitirGuiaRemision(guiaId);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('La guía quedó preparada. Revisa el detalle: $e'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }

      if (!mounted) return;
      if (_esEdicion) {
        Navigator.of(context).pop(true);
      } else {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => VerGuiaRemisionPage(guiaId: guiaId),
          ),
        );
      }
    } catch (e) {
      _error(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _error(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          _esEdicion ? 'Corregir Guía de Remisión' : 'Nueva Guía de Remisión',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: _color,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: _color))
          : ListView(
              padding: const EdgeInsets.all(18),
              children: [
                if (_esEdicion) ...[
                  _bannerEdicion(),
                  const SizedBox(height: 14),
                ],
                GreDocumentoSection(
                  color: _color,
                  tipoGuia: _form.tipoGuia,
                  motivoCodigo: _form.motivoCodigo,
                  motivos: _motivos,
                  documentoTipo: _form.documentoTipo,
                  documentoNumeroCtrl: _form.documentoNumeroCtrl,
                  fechaTraslado: _form.fechaTraslado,
                  observacionCtrl: _form.observacionCtrl,
                  remDocCtrl: _form.remDocCtrl,
                  remNombreCtrl: _form.remNombreCtrl,
                  onTipoGuiaChanged: _cambiarTipoGuia,
                  onMotivoCodigoChanged: (value) {
                    setState(() => _form.motivoCodigo = value);
                  },
                  onDocumentoTipoChanged: (value) {
                    setState(() => _form.documentoTipo = value);
                  },
                  onElegirFechaTraslado: _elegirFechaTraslado,
                ),
                const SizedBox(height: 14),
                GreRutaSection(
                  color: _color,
                  destTipo: _form.destTipo,
                  destDocCtrl: _form.destDocCtrl,
                  destNombreCtrl: _form.destNombreCtrl,
                  destDireccionCtrl: _form.destDireccionCtrl,
                  destUbigeoCtrl: _form.destUbigeoCtrl,
                  partidaDireccionCtrl: _form.partidaDireccionCtrl,
                  partidaUbigeoCtrl: _form.partidaUbigeoCtrl,
                  llegadaDireccionCtrl: _form.llegadaDireccionCtrl,
                  llegadaUbigeoCtrl: _form.llegadaUbigeoCtrl,
                  almacenes: _form.almacenes,
                  almacenPartidaId: _form.almacenPartidaId,
                  consultandoDestinatario: _consultandoDestinatario,
                  indTransbordo: _form.indTransbordo,
                  destinoEntregaTipo: _form.destinoEntregaTipo,
                  onDestTipoChanged: (value) {
                    setState(() => _form.destTipo = value);
                  },
                  onConsultarDestinatario: _consultarDestinatario,
                  onAlmacenChanged: (value) {
                    setState(() => _form.seleccionarAlmacen(value));
                  },
                  onUsarDireccionCliente: () {
                    setState(_form.usarDireccionClienteComoLlegada);
                  },
                  onLlegadaUbigeoSelected: (item) {
                    _form.destUbigeoCtrl.text = item['codigo']?.toString() ?? '';
                  },
                ),
                const SizedBox(height: 14),
                GreTransporteSection(
                  color: _color,
                  tipoGuia: _form.tipoGuia,
                  modalidad: _form.modalidad,
                  indTransbordo: _form.indTransbordo,
                  transportistaId: _form.transportistaId,
                  conductorId: _form.conductorId,
                  vehiculoId: _form.vehiculoId,
                  transportistaTransbordoId:
                      _form.transportistaTransbordoId,
                  agenciaOrigenId: _form.agenciaOrigenId,
                  agenciaDestinoId: _form.agenciaDestinoId,
                  destinoEntregaTipo: _form.destinoEntregaTipo,
                  transportistas: _form.transportistas,
                  agencias: _form.agencias,
                  conductores: _form.conductores,
                  vehiculos: _form.vehiculos,
                  onFlujoChanged: _cambiarFlujoTransporte,
                  onTransportistaChanged: (value) {
                    setState(() => _form.transportistaId = value);
                  },
                  onConductorChanged: (value) {
                    setState(() => _form.conductorId = value);
                  },
                  onVehiculoChanged: (value) {
                    setState(() => _form.vehiculoId = value);
                  },
                  onTransportistaTransbordoChanged:
                      _cambiarTransportistaTransbordo,
                  onAgenciaOrigenChanged: (value) {
                    setState(() => _form.agenciaOrigenId = value);
                  },
                  onDestinoEntregaTipoChanged: _cambiarDestinoEntregaTipo,
                  onAgenciaDestinoChanged: (value) {
                    setState(() => _form.aplicarAgenciaDestino(value));
                  },
                ),
                const SizedBox(height: 14),
                GreProductosSection(
                  color: _color,
                  detalles: _form.detalles,
                  onAgregar: _agregarProductoManual,
                  onEditar: _editarLinea,
                  onEliminar: (index) {
                    setState(() {
                      _form.detalles.removeAt(index);
                      _form.recalcularPeso();
                    });
                  },
                ),
                const SizedBox(height: 14),
                GrePesoSection(
                  color: _color,
                  controller: _form.pesoTotalCtrl,
                  cantidadBultosController: _form.cantidadBultosCtrl,
                  pesoEditado: _form.pesoEditado,
                  onPesoChanged: (_) {
                    if (!_form.pesoEditado) {
                      setState(() => _form.pesoEditado = true);
                    }
                  },
                  onRecalcular: () {
                    setState(() {
                      _form.pesoEditado = false;
                      _form.recalcularPeso();
                    });
                  },
                ),
                const SizedBox(height: 18),
                GreFormActions(
                  color: _color,
                  guardando: _guardando,
                  onGuardarBorrador: () => _guardar(emitir: false),
                  onEmitir: () => _guardar(emitir: true),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _bannerEdicion() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        _form.serieOriginal == null
            ? 'Editando borrador sin numerar.'
            : 'Corrigiendo ${_form.serieOriginal}-'
                '${_form.correlativoOriginal ?? ''}. '
                'Se conservará el mismo correlativo.',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}
