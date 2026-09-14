import 'package:intl/intl.dart';

/// Zona horaria fija de Lima, Perú (UTC-5).
/// No usamos TimeZone packages para mantener el proyecto simple;
/// la conversión manual es suficiente para un solo timezone fijo.
const _limaOffset = Duration(hours: -5);

/// Convierte cualquier [DateTime] o [String] ISO a hora Lima (UTC-5).
/// Es el reemplazo seguro de `.toLocal()` en toda la aplicación.
/// Al usar la zona fija UTC-5 se garantiza consistencia independientemente
/// de la configuración del reloj del dispositivo del empleado.
DateTime toLima(dynamic raw) {
  if (raw == null) return DateTime.now().toUtc().add(_limaOffset);
  DateTime dt;
  if (raw is DateTime) {
    dt = raw;
  } else {
    dt = DateTime.tryParse(raw.toString()) ??
        DateTime.now().toUtc().add(_limaOffset);
  }
  return dt.toUtc().add(_limaOffset);
}

class AppFormatters {
  // ─── MONEDA ──────────────────────────────────────────────────────────────────

  static String currency(num value, {int decimalDigits = 2}) {
    return NumberFormat.currency(
      locale: 'en_US',
      symbol: 'S/ ',
      decimalDigits: decimalDigits,
    ).format(value);
  }

  // ─── FECHAS (reciben DateTime ya convertido) ──────────────────────────────

  static String shortDate(DateTime value) =>
      DateFormat('dd/MM/yyyy').format(value);

  static String shortDateTime(DateTime value) =>
      DateFormat('dd/MM/yyyy HH:mm').format(value);

  // ─── FECHAS LIMA (reciben String ISO o DateTime desde la BD) ─────────────
  // Todas convierten el raw UTC → Lima (UTC-5) antes de formatear.

  /// "08/08 • 20:02" — para listas con fecha y hora compacta.
  static String limaDateTime(dynamic raw) {
    if (raw == null) return '--';
    return DateFormat('dd/MM • HH:mm').format(toLima(raw));
  }

  /// "20:02" — para tarjetas compactas donde solo importa la hora.
  static String limaTime(dynamic raw) {
    if (raw == null) return '--';
    return DateFormat('HH:mm').format(toLima(raw));
  }

  /// "08/08/2026 20:02" — para vistas detalladas.
  static String limaDateTimeLong(dynamic raw) {
    if (raw == null) return '--';
    return DateFormat('dd/MM/yyyy HH:mm').format(toLima(raw));
  }

  /// "08/08/2026" — solo fecha.
  static String limaDateOnly(dynamic raw) {
    if (raw == null) return '--';
    return DateFormat('dd/MM/yyyy').format(toLima(raw));
  }

  /// "08 ago 2026 • 20:02" — para encabezados de reportes y PDFs.
  static String limaDateTimeText(dynamic raw, {String locale = 'es'}) {
    if (raw == null) return '--';
    return DateFormat('dd MMM yyyy • HH:mm', locale).format(toLima(raw));
  }

  /// "08 ago 2026" — solo fecha en texto, para PDFs.
  static String limaDateText(dynamic raw, {String locale = 'es'}) {
    if (raw == null) return '--';
    return DateFormat('dd MMM yyyy', locale).format(toLima(raw));
  }

  /// "08 ago - 20:02" — formato compacto usado en ver_venta_page.
  static String limaMediumDateTime(dynamic raw, {String locale = 'es'}) {
    if (raw == null) return '--';
    return DateFormat('dd MMM - HH:mm', locale).format(toLima(raw));
  }

  // ─── NUMÉRICO ────────────────────────────────────────────────────────────────

  static double toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static int toInt(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
