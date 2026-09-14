/// Error de negocio redactado para presentación, sin dependencia de transporte.
class UserFacingException implements Exception {
  const UserFacingException(this.message);
  final String message;
  @override
  String toString() => message;
}
