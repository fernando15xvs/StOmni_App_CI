import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/service_catalog_use_case.dart';
import '../domain/service_record.dart';

class SupabaseServiceCatalogGateway implements ServiceCatalogGateway {
  const SupabaseServiceCatalogGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<ServiceRecord>> list({bool includeInactive = false}) async {
    final raw = await client.rpc(
      'list_services_v1',
      params: {'p_include_inactive': includeInactive},
    );
    if (raw is! List) {
      throw const FormatException('El catálogo de servicios es inválido.');
    }
    return raw.map(_decode).toList(growable: false);
  }

  @override
  Future<ServiceRecord> save(ServiceDraft draft) async {
    final raw = await client.rpc(
      'save_service_v1',
      params: {
        'p_service_id': draft.serviceId,
        'p_code': draft.code,
        'p_name': draft.name,
        'p_description': draft.description,
        'p_unit_price': draft.unitPrice,
        'p_purchase_price': draft.purchasePrice,
      },
    );
    return _decode(raw);
  }

  @override
  Future<void> deactivate(int serviceId) async {
    await client.rpc(
      'deactivate_service_v1',
      params: {'p_service_id': serviceId},
    );
  }

  ServiceRecord _decode(Object? raw) {
    if (raw is! Map) throw const FormatException('Servicio inválido.');
    final map = Map<String, dynamic>.from(raw);
    final id = map['id'] is num
        ? (map['id'] as num).toInt()
        : int.tryParse(map['id']?.toString() ?? '');
    final unitPrice = map['unit_price'] is num
        ? (map['unit_price'] as num).toDouble()
        : double.tryParse(map['unit_price']?.toString() ?? '');
    final purchasePrice = map['purchase_price'] is num
        ? (map['purchase_price'] as num).toDouble()
        : double.tryParse(map['purchase_price']?.toString() ?? '');
    if (id == null ||
        id <= 0 ||
        unitPrice == null ||
        !unitPrice.isFinite ||
        purchasePrice == null ||
        !purchasePrice.isFinite) {
      throw const FormatException('Contrato de servicio incompleto.');
    }
    return ServiceRecord(
      id: id,
      code: map['code']?.toString().trim() ?? '',
      name: map['name']?.toString().trim() ?? '',
      description: map['description']?.toString() ?? '',
      unitPrice: unitPrice,
      purchasePrice: purchasePrice,
      active: map['active'] != false,
    );
  }
}
