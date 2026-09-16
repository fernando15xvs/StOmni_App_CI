import 'package:flutter/widgets.dart';

typedef ResultadoInciertoDialogHandler =
    Future<bool> Function({
      required BuildContext context,
      required String tipoDocumento,
      required String documentoId,
    });

ResultadoInciertoDialogHandler? _handler;

/// Registra desde el composition root la implementación visual del módulo de
/// facturación. Core solo conoce la firma y no depende de ningún feature.
void configurarResultadoInciertoDialog(ResultadoInciertoDialogHandler handler) {
  _handler = handler;
}

Future<bool> mostrarReconciliacionResultadoIncierto({
  required BuildContext context,
  required String tipoDocumento,
  required String documentoId,
}) {
  final handler = _handler;
  if (handler == null) {
    throw StateError(
      'El diálogo de resultado incierto no fue configurado. Inicializa las dependencias de la app.',
    );
  }

  return handler(
    context: context,
    tipoDocumento: tipoDocumento,
    documentoId: documentoId,
  );
}
