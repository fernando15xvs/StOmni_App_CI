import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../documents/domain/generated_document.dart';
import '../../../pdf/pdf_branding.dart';
import '../../../pdf/pdf_document_theme.dart';
import '../../../utils/app_formatters.dart';
import '../data/balance_repository.dart';
import 'caja_cierre_pdf_renderer.dart';

final cajaCierrePdfServiceProvider = Provider<CajaCierrePdfService>((ref) {
  return CajaCierrePdfService(ref.watch(balanceRepositoryProvider));
});

class CajaCierrePdfService {
  CajaCierrePdfService(this._repository);

  final BalanceRepository _repository;

  Future<GeneratedDocument> generar(
    Map<String, dynamic> cajaInfo, {
    PdfBranding? branding,
    String ticketSize = '80mm',
  }) async {
    final apertura = toLima(cajaInfo['fecha_apertura']);
    final cierre = toLima(cajaInfo['fecha_cierre']);
    final movimientos = await _repository.getMovimientosByFechas(
      apertura,
      cierre,
    );
    final bytes = await CajaCierrePdfRenderer.generar(
      cajaInfo,
      movimientos,
      branding: branding,
      ticketSize: ticketSize,
    );
    final fecha = cajaInfo['fecha_cierre']?.toString() ?? '';
    final suffix = fecha.length >= 10 ? fecha.substring(0, 10) : 'sin_fecha';

    final format = PdfDocumentTheme.ticketFormat(size: ticketSize);
    return GeneratedDocument(
      bytes: bytes,
      fileName: 'Ticket_Cierre_Caja_$suffix.pdf',
      kind: DocumentKind.pdf,
      pageWidthPoints: format.width,
      pageHeightPoints: format.height,
    );
  }
}
