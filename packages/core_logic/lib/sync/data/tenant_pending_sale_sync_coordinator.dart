import '../../database/legacy_pending_sale_quarantine.dart';
import '../../database/pending_sale_queue_store.dart';
import '../../database/tenant_pending_sale_queue.dart';
import '../../features/ventas/data/pending_sale_mapper.dart';
import '../../features/ventas/domain/sale_models.dart';
import '../../onboarding/application/tenant_request_scope.dart';

/// A trusted adapter must submit the write under the selected organization
/// on THAT request, never by editing shared SupabaseClient headers. The
/// server still validates auth.uid(), membership, permissions and tenant.
abstract interface class TenantScopedSaleSyncAdapter {
  Future<void> sendTicket({
    required TenantRequestScope scope,
    required PendingSale sale,
  });
}

typedef TenantSyncMembershipVerifier =
    Future<VerifiedTenantRequestContext> Function(TenantRequestScope scope);

final class TenantPendingSaleSyncResult {
  const TenantPendingSaleSyncResult({
    required this.submitted,
    required this.failed,
    required this.skippedProcessing,
    required this.remaining,
  });

  final int submitted;
  final int failed;
  final int skippedProcessing;
  final int remaining;
}

/// I3 integration boundary for locally scoped tickets. Not yet connected to
/// the operational sale-writing RPC, which must implement per-request tenant
/// selection and server-side access checks before activating multi-company.
///
/// In-progress sales are retained when Auth or selected company changes:
/// server-side idempotency by request_id is mandatory for safe retries.
final class TenantPendingSaleSyncCoordinator {
  TenantPendingSaleSyncCoordinator({
    required this.queue,
    required this.scope,
    required this.currentAuthUserId,
    required this.currentSelectedOrganizationId,
    required this.legacyQuarantine,
    required this.verifySelectedTenant,
    required this.adapter,
  });

  final TenantPendingSaleQueue queue;
  final TenantRequestScope scope;
  final String? Function() currentAuthUserId;
  final String? Function() currentSelectedOrganizationId;
  final LegacyPendingSaleQuarantine legacyQuarantine;
  final TenantSyncMembershipVerifier verifySelectedTenant;
  final TenantScopedSaleSyncAdapter adapter;

  Future<TenantPendingSaleSyncResult>? _inFlight;

  /// One coordinator cannot submit the same batch twice concurrently.
  /// Additional windows must also use server-side request_id idempotency.
  Future<TenantPendingSaleSyncResult> synchronize() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = _synchronize();
    _inFlight = run;
    run.then<void>(
      (_) {
        if (identical(_inFlight, run)) _inFlight = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_inFlight, run)) _inFlight = null;
      },
    );
    return run;
  }

  bool _stillSelected() =>
      currentAuthUserId() == scope.authUserId &&
      currentSelectedOrganizationId() == scope.organizationId;

  Future<T> _withinSelectedSession<T>(Future<T> Function() request) =>
      scope.execute<T>(
        currentAuthUserId: currentAuthUserId,
        currentSelectedOrganizationId: currentSelectedOrganizationId,
        request: (_) => request(),
      );

  Future<void> _requireServerMembership() async {
    final context = await _withinSelectedSession(
      () => verifySelectedTenant(scope),
    );
    if (context.organizationId != scope.organizationId ||
        (context.baseRole != 'admin' && context.baseRole != 'operador')) {
      throw StateError('El backend no autorizó el tenant seleccionado.');
    }
  }

  Future<TenantPendingSaleSyncResult> _synchronize() async {
    if (!_stillSelected()) {
      throw StateError('La sesión o empresa cambió antes de sincronizar.');
    }

    // Historical unowned sales must be reconciled under the former single-
    // tenant flow; never pull them into a new organization's queue silently.
    await _withinSelectedSession(
      () => legacyQuarantine.requireNoUnattributedTickets(),
    );
    await _requireServerMembership();

    final records = await queue.list();
    var submitted = 0;
    var failed = 0;
    var skippedProcessing = 0;

    for (final record in records) {
      if (!_stillSelected()) {
        throw StateError('La sesión o empresa cambió durante sincronización.');
      }
      if (record.status == PendingSaleQueueStatus.processing) {
        // No automatic reset of a possibly live worker's lease.
        skippedProcessing++;
        continue;
      }

      try {
        final sale = PendingSaleMapper.decode(record.payload);
        if (sale.requestId != record.requestId ||
            sale.authUserId != scope.authUserId ||
            sale.tipoComprobante.toLowerCase() != 'ticket_interno' ||
            DateTime.tryParse(sale.fecha) == null) {
          throw const FormatException(
            'Ticket sin identidad, idempotencia o fecha válida.',
          );
        }

        // Revocation can occur between records, so refresh selected context.
        await _requireServerMembership();
        await queue.markProcessing(record.requestId);
        await _withinSelectedSession(
          () => adapter.sendTicket(scope: scope, sale: sale),
        );

        // If Auth switches while the request commits, do NOT delete the
        // local ticket: retry with the same request_id after revalidation.
        await queue.deleteByRequestId(record.requestId);
        submitted++;
      } catch (_) {
        if (!_stillSelected()) {
          throw StateError(
            'La sesión cambió: el ticket se conserva para reintento seguro.',
          );
        }
        await queue.markFailed(
          record.requestId,
          'No se pudo verificar o sincronizar el Ticket Interno.',
        );
        failed++;
      }
    }

    final remaining = await queue.count();
    return TenantPendingSaleSyncResult(
      submitted: submitted,
      failed: failed,
      skippedProcessing: skippedProcessing,
      remaining: remaining,
    );
  }
}
