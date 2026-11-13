import 'tenant_request_scope.dart';

/// One selection lifecycle PER UI session/window. Never store the selected
/// organization in a singleton, JWT metadata or global Supabase headers.
///
/// This object may validate a candidate for preview, but does not authorize
/// business Home or offline sync until the operational I3 integration is ready.
final class TenantSelectionSession {
  TenantSelectionSession({required this.currentAuthUserId});

  final String? Function() currentAuthUserId;

  VerifiedTenantRequestContext? _verified;
  String? _candidateOrganizationId;
  int _generation = 0;

  String? get activeOrganizationId => _verified?.organizationId;
  String? get activeBaseRole => _verified?.baseRole;

  /// Request-local validator can select a pending candidate in its RPC.
  /// Operational code must use activeOrganizationId instead.
  String? get requestOrganizationId =>
      _candidateOrganizationId ?? activeOrganizationId;

  bool get isVerifying => _candidateOrganizationId != null;

  /// Verify the chosen company at the backend under current auth.uid().
  /// During verification the previous company is no longer operationally
  /// selected. Older requests cannot activate after a newer selection.
  Future<VerifiedTenantRequestContext> verifySelection({
    required String organizationId,
    required Future<VerifiedTenantRequestContext> Function(TenantRequestScope)
    verify,
  }) async {
    final userId = currentAuthUserId();
    if (userId == null || userId.isEmpty) {
      throw StateError('La sesión de usuario ya no está disponible.');
    }

    final scope = TenantRequestScope(
      authUserId: userId,
      organizationId: organizationId,
    );

    final attempt = ++_generation;
    _verified = null;
    _candidateOrganizationId = organizationId;

    try {
      final result = await verify(scope);
      if (attempt != _generation ||
          currentAuthUserId() != userId ||
          _candidateOrganizationId != organizationId) {
        throw StateError('La sesión cambió mientras se seleccionaba empresa.');
      }
      if (result.organizationId != organizationId ||
          (result.baseRole != 'admin' && result.baseRole != 'operador')) {
        throw StateError('El servidor no autorizó la empresa seleccionada.');
      }
      _candidateOrganizationId = null;
      _verified = result;
      return result;
    } catch (_) {
      if (attempt == _generation) {
        _candidateOrganizationId = null;
        _verified = null;
      }
      rethrow;
    }
  }

  /// Required on logout, tenant revocation, or disposal of the owning window.
  void clear() {
    ++_generation;
    _candidateOrganizationId = null;
    _verified = null;
  }
}
