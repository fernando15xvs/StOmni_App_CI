import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import '../state/gre_form_model.dart';

class GreSubmissionCoordinator {
  const GreSubmissionCoordinator._();

  static GrePreparedSubmission preparar({
    required GreFormModel form,
    required bool emitir,
    required Map<String, String> motivos,
    String? guiaId,
    int? ventaId,
    int? transferenciaId,
    DateTime? ahoraLima,
  }) {
    if (form.detalles.isEmpty) {
      throw const FormatException('Agrega al menos un producto.');
    }

    final origenTipo = form.origenTipo(
      ventaId: ventaId,
      transferenciaId: transferenciaId,
    );
    final almacenesDetalle = form.detalles
        .map((item) => item['almacen_id'])
        .whereType<int>()
        .toSet();

    if (origenTipo == 'venta' && almacenesDetalle.length > 1) {
      throw const FormatException(
        'La venta contiene productos de varios almacenes. '
        'Emite una guía separada por cada punto de partida.',
      );
    }

    if (origenTipo == 'venta' && almacenesDetalle.length == 1) {
      final almacenReal = almacenesDetalle.first;
      if (form.almacenPartidaId != almacenReal) {
        form.seleccionarAlmacen(almacenReal);
      }
    }

    final peso = double.tryParse(
      form.pesoTotalCtrl.text.trim().replaceAll(',', '.'),
    );
    final cantidadBultosTexto = form.cantidadBultosCtrl.text.trim();
    final cantidadBultos = cantidadBultosTexto.isEmpty
        ? null
        : int.tryParse(cantidadBultosTexto);

    if (cantidadBultosTexto.isNotEmpty &&
        (cantidadBultos == null || cantidadBultos <= 0)) {
      throw const FormatException(
        'El número de bultos debe ser un entero mayor a cero.',
      );
    }

    if (emitir) {
      _validarEmision(form, peso, ahoraLima: ahoraLima);
    }

    return GrePreparedSubmission._(
      form: form,
      emitir: emitir,
      motivos: motivos,
      guiaId: guiaId,
      ventaId: ventaId,
      transferenciaId: transferenciaId,
      origenTipo: origenTipo,
      peso: peso,
      cantidadBultos: cantidadBultos,
    );
  }

  static void _validarEmision(
    GreFormModel form,
    double? peso, {
    DateTime? ahoraLima,
  }) {
    final ahora = ahoraLima ?? AppTime.now();
    form.fechaEmision = ahora;
    final inicioMinimo = GreFormRules.redondearHaciaArribaAlMinuto(
      ahora.add(const Duration(minutes: 1)),
    );

    if (form.fechaTraslado.isBefore(inicioMinimo)) {
      throw FormatException(
        'El traslado debe comenzar después de emitir la guía. '
        'Selecciona como mínimo '
        '${DateFormat('dd/MM/yyyy HH:mm').format(inicioMinimo)}.',
      );
    }

    if (form.partidaDireccionCtrl.text.trim().length < 5 ||
        !RegExp(r'^[0-9]{6}$').hasMatch(form.partidaUbigeoCtrl.text.trim())) {
      throw const FormatException(
        'Selecciona una dirección y ubigeo válidos de partida.',
      );
    }

    if (form.llegadaDireccionCtrl.text.trim().length < 5 ||
        !RegExp(r'^[0-9]{6}$').hasMatch(form.llegadaUbigeoCtrl.text.trim())) {
      throw const FormatException(
        'Selecciona una dirección y ubigeo válidos de llegada.',
      );
    }

    if (form.destDocCtrl.text.trim().isEmpty ||
        form.destNombreCtrl.text.trim().isEmpty) {
      throw const FormatException('Completa el destinatario.');
    }

    if (form.indTransbordo) {
      if (form.tipoGuia != 'remitente' || form.modalidad != '02') {
        throw const FormatException(
          'El transbordo programado requiere una GRE Remitente con '
          'primer tramo privado.',
        );
      }
      if (form.transportistaTransbordoId == null ||
          form.agenciaOrigenId == null) {
        throw const FormatException(
          'Selecciona la empresa transportista y la agencia donde '
          'entregarás los productos.',
        );
      }
      if (form.destinoEntregaTipo == 'agencia' &&
          form.agenciaDestinoId == null) {
        throw const FormatException('Selecciona la agencia de destino.');
      }
      if (form.destinoEntregaTipo == 'agencia' &&
          form.agenciaOrigenId == form.agenciaDestinoId) {
        throw const FormatException(
          'La agencia de origen y la agencia de destino deben ser distintas.',
        );
      }
    }

    if (form.modalidad == '01' && form.tipoGuia == 'remitente') {
      if (form.transportistaId == null) {
        throw const FormatException(
          'En transporte público selecciona una empresa transportista.',
        );
      }
    } else {
      if (form.conductorId == null || form.vehiculoId == null) {
        throw const FormatException('Selecciona conductor y vehículo.');
      }

      final conductor = form.conductores.cast<Map<String, dynamic>?>().firstWhere(
            (item) => (item?['id'] as num?)?.toInt() == form.conductorId,
            orElse: () => null,
          );
      final vehiculo = form.vehiculos.cast<Map<String, dynamic>?>().firstWhere(
            (item) => (item?['id'] as num?)?.toInt() == form.vehiculoId,
            orElse: () => null,
          );

      if ((conductor?['numero_licencia']?.toString().trim() ?? '').isEmpty ||
          (conductor?['apellidos']?.toString().trim() ?? '').isEmpty) {
        throw const FormatException(
          'El conductor debe tener licencia, nombres y apellidos.',
        );
      }

      if ((vehiculo?['marca']?.toString().trim() ?? '').isEmpty ||
          (vehiculo?['constancia_inscripcion']?.toString().trim() ?? '')
              .isEmpty) {
        throw const FormatException(
          'El vehículo debe tener placa, marca y constancia '
          'de inscripción o habilitación.',
        );
      }
    }

    if (form.tipoGuia == 'transportista') {
      if (form.empresa?['gre_transportista_habilitada'] != true) {
        throw const FormatException(
          'La GRE Transportista está deshabilitada para esta empresa.',
        );
      }
      if (form.remDocCtrl.text.trim().isEmpty ||
          form.remNombreCtrl.text.trim().isEmpty ||
          form.documentoNumeroCtrl.text.trim().isEmpty) {
        throw const FormatException(
          'La GRE Transportista requiere remitente y '
          'GRE Remitente relacionada.',
        );
      }
      form.documentoTipo = '09';
    }

    if (peso == null || peso <= 0) {
      throw const FormatException('El peso total debe ser mayor a cero.');
    }
  }
}

class GrePreparedSubmission {
  const GrePreparedSubmission._({
    required this.form,
    required this.emitir,
    required this.motivos,
    required this.guiaId,
    required this.ventaId,
    required this.transferenciaId,
    required this.origenTipo,
    required this.peso,
    required this.cantidadBultos,
  });

  final GreFormModel form;
  final bool emitir;
  final Map<String, String> motivos;
  final String? guiaId;
  final int? ventaId;
  final int? transferenciaId;
  final String origenTipo;
  final double? peso;
  final int? cantidadBultos;

  Future<String> guardar(GuiasRemisionRepository repository) async {
    final result = await repository.guardarGuia(
      guiaId: guiaId,
      requestId: form.requestId,
      emitir: emitir,
      tipoGuia: form.tipoGuia,
      origenTipo: origenTipo,
      ventaId: ventaId ?? form.ventaIdGuardada,
      transferenciaId: transferenciaId ?? form.transferenciaIdGuardada,
      documentoRelacionadoTipo:
          (form.documentoTipo == null || form.documentoTipo!.isEmpty)
              ? null
              : form.documentoTipo,
      documentoRelacionadoNumero: form.documentoNumeroCtrl.text.trim().isEmpty
          ? null
          : form.documentoNumeroCtrl.text.trim(),
      motivoCodigo: form.motivoCodigo,
      motivoDescripcion: motivos[form.motivoCodigo]!,
      modalidadTransporte: form.modalidad,
      fechaEmision: form.fechaEmision,
      fechaTraslado: form.fechaTraslado,
      destinatario: {
        'tipo_documento': form.destTipo,
        'numero_documento': form.destDocCtrl.text.trim(),
        'razon_social': form.destNombreCtrl.text.trim(),
        'direccion': form.destDireccionCtrl.text.trim(),
        'ubigeo': form.destUbigeoCtrl.text.trim(),
      },
      remitente: {
        'tipo_documento': form.remTipo,
        'numero_documento': form.remDocCtrl.text.trim(),
        'razon_social': form.remNombreCtrl.text.trim(),
      },
      partida: {
        'direccion': form.partidaDireccionCtrl.text.trim(),
        'ubigeo': form.partidaUbigeoCtrl.text.trim(),
      },
      llegada: {
        'direccion': form.llegadaDireccionCtrl.text.trim(),
        'ubigeo': form.llegadaUbigeoCtrl.text.trim(),
      },
      transportistaId: form.modalidad == '01' && form.tipoGuia == 'remitente'
          ? form.transportistaId
          : null,
      conductorId: form.modalidad == '01' && form.tipoGuia == 'remitente'
          ? null
          : form.conductorId,
      vehiculoId: form.modalidad == '01' && form.tipoGuia == 'remitente'
          ? null
          : form.vehiculoId,
      indTransbordo: form.indTransbordo,
      transportistaTransbordoId:
          form.indTransbordo ? form.transportistaTransbordoId : null,
      agenciaOrigenId: form.indTransbordo ? form.agenciaOrigenId : null,
      agenciaDestinoId:
          form.indTransbordo && form.destinoEntregaTipo == 'agencia'
              ? form.agenciaDestinoId
              : null,
      destinoEntregaTipo:
          form.indTransbordo ? form.destinoEntregaTipo : 'direccion_cliente',
      pesoTotal: peso,
      cantidadBultos: cantidadBultos,
      pesoEditado: form.pesoEditado,
      observacion: form.observacionCtrl.text.trim(),
      detalles: form.detalles,
    );

    final id = result['guia_id']?.toString();
    if (id == null || id.isEmpty) {
      throw StateError('Supabase no devolvió el ID de la guía.');
    }
    return id;
  }
}
