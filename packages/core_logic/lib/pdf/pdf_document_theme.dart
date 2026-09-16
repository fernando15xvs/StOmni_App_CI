import 'package:pdf/pdf.dart';

class PdfDocumentTheme {
  const PdfDocumentTheme._();

  static const PdfColor verde = PdfColor.fromInt(0xFF4CAF50);
  static const PdfColor indigo = PdfColor.fromInt(0xFF3949AB);
  static const PdfColor azul = PdfColor.fromInt(0xFF1E3D59);
  static const PdfColor negro = PdfColor.fromInt(0xFF000000);
  static const PdfColor grisClaro = PdfColor.fromInt(0xFFEEEEEE);

  static PdfPageFormat ticketFormat({String size = '80mm'}) {
    if (size == '58mm') {
      return PdfPageFormat(58 * PdfPageFormat.mm, double.infinity);
    }
    if (size == 'a4') return PdfPageFormat.a4;
    return PdfPageFormat(80 * PdfPageFormat.mm, double.infinity);
  }
}
