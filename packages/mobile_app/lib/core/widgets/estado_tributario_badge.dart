import 'package:flutter/material.dart';

/// Badge reutilizable para mostrar el estado de un documento tributario
/// (comprobante, nota de crédito, guía de remisión, proceso tributario).
///
/// Centraliza la lógica de color y texto que antes estaba duplicada
/// en [DocumentosElectronicosPage], [VerNotaCreditoPage],
/// [GestionTributariaPage] y [VerVentaPage].
class EstadoTributarioBadge extends StatelessWidget {
  final String estado;

  /// Tamaño de la fuente del badge. Por defecto 9.
  final double fontSize;

  const EstadoTributarioBadge({
    super.key,
    required this.estado,
    this.fontSize = 9,
  });

  /// Devuelve el color asociado al [estado].
  static Color colorDeEstado(String estado) {
    return switch (estado.toLowerCase().trim()) {
      'aceptado' || 'aceptada' => Colors.green,
      'rechazado' || 'rechazada' => Colors.red,
      'ticket_pendiente' => Colors.blue,
      'procesando' => Colors.blueGrey,
      'resultado_incierto' => Colors.deepOrange,
      'xml_validado_prueba' => Colors.teal,
      _ => Colors.orange,
    };
  }

  /// Devuelve el texto corto para mostrar en el badge.
  static String textoDeEstado(String estado) {
    return switch (estado.toLowerCase().trim()) {
      'aceptado' || 'aceptada' => 'ACEPTADO',
      'rechazado' || 'rechazada' => 'RECHAZADO',
      'ticket_pendiente' => 'EN SUNAT',
      'procesando' => 'PROCESANDO',
      'pendiente_envio' => 'PENDIENTE',
      'pendiente_reintento' => 'REINTENTO',
      'resultado_incierto' => 'INCIERTO',
      'xml_validado_prueba' => 'XML PRUEBA',
      _ => estado.toUpperCase(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = colorDeEstado(estado);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        textoDeEstado(estado),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
