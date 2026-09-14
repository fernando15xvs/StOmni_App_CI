/// Reglas puras del formulario GRE que no dependen de Flutter ni Supabase.
class GreFormRules {
  const GreFormRules._();

  static const Duration _offsetLima = Duration(hours: 5);

  /// Convierte un `timestamptz` recibido desde Supabase a la representación
  /// interna usada por la app: hora de pared de Lima empaquetada como UTC.
  ///
  /// Ejemplo:
  /// `2026-08-19T00:49:02Z` representa 18/08/2026 19:49 en Lima y se
  /// convierte en `DateTime.utc(2026, 8, 18, 19, 49, 2)`.
  ///
  /// Esto evita que, al reabrir un borrador y volver a enviarlo con `-05:00`,
  /// se sumen cinco horas en cada guardado.
  static DateTime? desdeSupabaseALima(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return null;

    final instantUtc = parsed.toUtc();
    final lima = instantUtc.subtract(_offsetLima);

    return DateTime.utc(
      lima.year,
      lima.month,
      lima.day,
      lima.hour,
      lima.minute,
      lima.second,
      lima.millisecond,
      lima.microsecond,
    );
  }

  /// Redondea hacia arriba porque el selector de hora trabaja por minutos.
  /// Ejemplo: 15:30:48 -> 15:31:00.
  ///
  /// Preserva si el valor usa UTC. Esto es importante porque Nueva GRE
  /// representa la hora de pared de Lima como `DateTime.utc(...)`; convertirla
  /// accidentalmente a `DateTime(...)` haría que las comparaciones dependan de
  /// la zona horaria del dispositivo (por ejemplo, UTC-5 en Windows Perú).
  static DateTime redondearHaciaArribaAlMinuto(DateTime value) {
    final sinSegundos = value.isUtc
        ? DateTime.utc(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
          )
        : DateTime(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
          );

    final yaEstaExacto =
        value.second == 0 && value.millisecond == 0 && value.microsecond == 0;

    return yaEstaExacto
        ? sinSegundos
        : sinSegundos.add(const Duration(minutes: 1));
  }

  /// Mantiene la regla actual del formulario: el traslado debe iniciar al
  /// menos un minuto después del instante seguro usado para emitir.
  static DateTime inicioTrasladoMinimo(DateTime ahoraSeguro) {
    return redondearHaciaArribaAlMinuto(
      ahoraSeguro.add(const Duration(minutes: 1)),
    );
  }

  static String flujoTransporte({
    required String tipoGuia,
    required String modalidadTransporte,
    required bool indTransbordo,
  }) {
    if (tipoGuia == 'transportista') return 'transportista';
    if (indTransbordo) return 'transbordo';
    return modalidadTransporte == '01' ? 'publico' : 'privado';
  }

  static bool ubigeoValido(String value) {
    return RegExp(r'^[0-9]{6}$').hasMatch(value.trim());
  }
}
