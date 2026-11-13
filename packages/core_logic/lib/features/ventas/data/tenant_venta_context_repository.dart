import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../onboarding/application/tenant_request_scope.dart';
import '../application/venta_application_ports.dart';

/// Prepared I3 implementation of the existing sale context port.
///
/// Every individual REST/RPC builder selects one tenant. This is a *request
/// selector*, not an authorization grant: RLS and SECURITY DEFINER RPCs must
/// revalidate the actual Auth JWT, role, membership and employee state.
///
/// Do not register with operational sale UI until the processing authorizer,
/// business policy, cash, inventory and fiscal gateways are scoped together.
final class TenantVentaContextRepository implements VentaContextGateway {
  const TenantVentaContextRepository(
    this._client, {
    required this.scope,
    required this.currentSelectedOrganizationId,
  });

  final SupabaseClient _client;
  final TenantRequestScope scope;
  final String? Function() currentSelectedOrganizationId;

  @override
  String? get currentAuthUserId => _client.auth.currentUser?.id;

  Future<T> _authorized<T>(Future<T> Function(String organizationId) request) {
    return scope.execute<T>(
      currentAuthUserId: () => _client.auth.currentUser?.id,
      currentSelectedOrganizationId: currentSelectedOrganizationId,
      request: (organizationId) async {
        // Revalidate the server-selected company before every auxiliary
        // operation. None of the following requests may infer another tenant.
        final response = await _client
            .rpc('get_my_tenant_context_v1')
            .setHeader(TenantRequestScope.organizationHeader, organizationId);
        VerifiedTenantRequestContext.fromServer(
          response,
          requestedOrganizationId: organizationId,
        );
        return request(organizationId);
      },
    );
  }

  static Map<String, dynamic> requireOwnRow(
    Object? raw, {
    required String organizationId,
  }) {
    if (raw is! Map) {
      throw const FormatException('Fila de empresa inválida.');
    }
    final row = Map<String, dynamic>.from(raw);
    if (row['organization_id'] != organizationId ||
        row['id'] is! num ||
        (row['id'] as num).toInt() <= 0) {
      throw StateError('Fila no autorizada para la empresa seleccionada.');
    }
    return row;
  }

  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) =>
      _authorized((organizationId) async {
        // An explicit seller ID is never accepted without proving its tenant.
        // Without one, use the canonical current user's employee membership.
        final builder = _client
            .from('empleados')
            .select('id, organization_id')
            .eq('organization_id', organizationId)
            .eq('activo', true);
        final response = vendedorId == null
            ? await builder
                  .eq('app_user_id', scope.authUserId)
                  .maybeSingle()
                  .setHeader(
                    TenantRequestScope.organizationHeader,
                    organizationId,
                  )
            : await builder
                  .eq('id', vendedorId)
                  .maybeSingle()
                  .setHeader(
                    TenantRequestScope.organizationHeader,
                    organizationId,
                  );
        if (response == null) {
          throw StateError('No existe vendedor activo en esta empresa.');
        }
        return (requireOwnRow(
          response,
          organizationId: organizationId,
        )['id'] as num).toInt();
      });

  @override
  Future<bool> cajaChicaAbierta() => _authorized((organizationId) async {
    final response = await _client
        .rpc('get_estado_caja_chica')
        .setHeader(TenantRequestScope.organizationHeader, organizationId);
    if (response is! Map) {
      throw const FormatException('Caja Chica devolvió datos inválidos.');
    }
    final state = response['estado'];
    if (state != 'ABIERTA' && state != 'CERRADA') {
      throw const FormatException('Estado de Caja Chica desconocido.');
    }
    return state == 'ABIERTA';
  });

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) => _authorized((organizationId) async {
    final inputDocument = ruc.trim();
    final inputName = nombre.trim();
    final inputAddress = direccion.trim();

    final document = inputDocument.isNotEmpty
        ? inputDocument
        : (inputName.isNotEmpty || inputAddress.isNotEmpty
              ? 'SD-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}'
              : '00000000');
    final finalName = inputName.isNotEmpty
        ? inputName
        : (inputDocument.isNotEmpty ? 'Cliente' : 'Cliente General');
    final finalAddress = inputAddress.isNotEmpty ? inputAddress : '-';

    // The table is RLS-protected and the explicit organization filter also
    // prevents a malicious/stale client from overwriting another tenant.
    Future<Map<String, dynamic>?> lookup() async {
      final row = await _client
          .from('clientes')
          .select('id, organization_id')
          .eq('organization_id', organizationId)
          .eq('dni_ruc', document)
          .maybeSingle()
          .setHeader(
            TenantRequestScope.organizationHeader,
            organizationId,
          );
      return row == null
          ? null
          : requireOwnRow(row, organizationId: organizationId);
    }

    final existing = await lookup();
    if (existing != null) {
      final customerId = (existing['id'] as num).toInt();
      final updated = await _client
          .from('clientes')
          .update({'nombre': finalName, 'direccion': finalAddress})
          .eq('organization_id', organizationId)
          .eq('id', customerId)
          .select('id, organization_id')
          .single()
          .setHeader(
            TenantRequestScope.organizationHeader,
            organizationId,
          );
      return (requireOwnRow(
        updated,
        organizationId: organizationId,
      )['id'] as num).toInt();
    }

    try {
      final inserted = await _client
          .from('clientes')
          .insert({
            'organization_id': organizationId,
            'dni_ruc': document,
            'nombre': finalName,
            'direccion': finalAddress,
          })
          .select('id, organization_id')
          .single()
          .setHeader(
            TenantRequestScope.organizationHeader,
            organizationId,
          );
      return (requireOwnRow(
        inserted,
        organizationId: organizationId,
      )['id'] as num).toInt();
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
      final recovered = await lookup();
      if (recovered == null) rethrow;
      return (recovered['id'] as num).toInt();
    }
  });
}
