import 'package:http/http.dart' as http;

class AppTime {
  AppTime._();

  static Duration _offset = Duration.zero;
  static bool _synced = false;

  /// Sincroniza la hora contra la cabecera HTTP `Date` de un servidor externo.
  ///
  /// Si la consulta falla, la app continúa funcionando con el reloj local y
  /// [isSynced] queda en `false`.
  static Future<void> sync() async {
    try {
      final before = DateTime.now();
      final response = await http
          .head(Uri.parse('https://google.com'))
          .timeout(const Duration(seconds: 5));

      final dateHeader = response.headers['date'];
      final serverTime = dateHeader == null ? null : _parseHttpDate(dateHeader);
      if (serverTime != null) {
        final after = DateTime.now();
        final latency = (after.difference(before)) ~/ 2;
        _offset = serverTime.subtract(latency).difference(after.toUtc());
        _synced = true;
        return;
      }
    } catch (_) {}

    _offset = Duration.zero;
    _synced = false;
  }

  /// Parsea el formato RFC-1123 habitual de la cabecera HTTP `Date` sin
  /// depender de `dart:io`, lo que mantiene este helper compatible con Web.
  static DateTime? _parseHttpDate(String value) {
    try {
      final normalized = value.replaceAll(',', '').trim();
      final parts = normalized.split(RegExp(r'\s+'));
      if (parts.length < 6) return null;

      const months = <String, int>{
        'Jan': 1,
        'Feb': 2,
        'Mar': 3,
        'Apr': 4,
        'May': 5,
        'Jun': 6,
        'Jul': 7,
        'Aug': 8,
        'Sep': 9,
        'Oct': 10,
        'Nov': 11,
        'Dec': 12,
      };

      final day = int.parse(parts[1]);
      final month = months[parts[2]];
      final year = int.parse(parts[3]);
      final time = parts[4].split(':');
      if (month == null || time.length != 3) return null;

      return DateTime.utc(
        year,
        month,
        day,
        int.parse(time[0]),
        int.parse(time[1]),
        int.parse(time[2]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Devuelve la hora real actual de Lima, Perú (UTC-5), empaquetada como UTC.
  /// Esto es CRÍTICO para mantener la compatibilidad con la base de datos,
  /// la cual espera que la hora de Lima se envíe con el marcador "Z" (Fake UTC).
  static DateTime now() {
    final realUtc = DateTime.now().toUtc().add(_offset);
    final limaTime = realUtc.subtract(const Duration(hours: 5));

    return DateTime.utc(
      limaTime.year,
      limaTime.month,
      limaTime.day,
      limaTime.hour,
      limaTime.minute,
      limaTime.second,
      limaTime.millisecond,
    );
  }

  /// Devuelve la hora actual en UTC, sincronizada con el servidor.
  static DateTime nowUtc() {
    return DateTime.now().toUtc().add(_offset);
  }

  /// Devuelve `true` si la sincronización con el servidor fue exitosa.
  static bool get isSynced => _synced;

  /// Devuelve la hora Lima actual como ISO 8601 con offset -05:00.
  static String nowIso() => toIsoLima(now());

  /// Devuelve solo la fecha de hoy en Lima (sin hora).
  static DateTime today() {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Devuelve el inicio del día de hoy en Lima (00:00:00).
  static DateTime startOfToday() => today();

  /// Devuelve el fin del día de hoy en Lima (23:59:59).
  static DateTime endOfToday() {
    final n = now();
    return DateTime(n.year, n.month, n.day, 23, 59, 59);
  }

  /// Convierte [value] a un string ISO 8601 con el offset fijo de Lima (-05:00).
  ///
  /// Ejemplo: `2026-08-09T00:00:00-05:00`
  /// Se usa para enviar rangos de fecha a los RPCs de Supabase.
  static String toIsoLima(DateTime value) {
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${pad(value.year, 4)}-${pad(value.month)}-${pad(value.day)}'
        'T${pad(value.hour)}:${pad(value.minute)}:${pad(value.second)}'
        '-05:00';
  }
}
