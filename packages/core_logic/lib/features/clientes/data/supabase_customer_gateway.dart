import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/customer_use_case.dart';

class SupabaseCustomerGateway implements CustomerGateway {
  const SupabaseCustomerGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<CustomerRecord>> list({
    int limit = 50,
    int offset = 0,
    String query = '',
  }) async {
    var request = client.from('clientes').select();
    final text = query.trim();
    if (text.isNotEmpty) {
      request = request.or('nombre.ilike.%$text%,dni_ruc.ilike.%$text%');
    }
    final rows = await request
        .order('nombre')
        .range(offset, offset + limit - 1);
    return rows.map(_decode).toList(growable: false);
  }

  @override
  Future<bool> documentExists(String document, {int? excludingId}) async {
    final value = document.trim();
    if (value.isEmpty) return false;
    var request = client.from('clientes').select('id').eq('dni_ruc', value);
    if (excludingId != null) request = request.neq('id', excludingId);
    return await request.limit(1).maybeSingle() != null;
  }

  @override
  Future<CustomerRecord> save(CustomerDraft draft, {int? id}) async {
    final payload = <String, dynamic>{
      'nombre': draft.name,
      'dni_ruc': draft.document,
      'direccion': draft.address,
      if (draft.documentType != null && draft.documentType!.isNotEmpty)
        'tipo_doc': draft.documentType,
      if (draft.phone != null && draft.phone!.isNotEmpty)
        'telefono': draft.phone,
    };
    final Object? raw;
    if (id == null) {
      raw = await client.from('clientes').insert(payload).select().single();
    } else {
      raw = await client
          .from('clientes')
          .update(payload)
          .eq('id', id)
          .select()
          .single();
    }
    return _decode(raw);
  }

  @override
  Future<void> delete(int id) async {
    await client.from('clientes').delete().eq('id', id);
  }

  CustomerRecord _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Registro de cliente inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final rawId = map['id'];
    final id = rawId is num
        ? rawId.toInt()
        : int.tryParse(rawId?.toString() ?? '');
    final name = map['nombre']?.toString().trim() ?? '';
    if (id == null || id <= 0 || name.isEmpty) {
      throw const FormatException('El cliente no tiene id o nombre válido.');
    }
    String? optional(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }
    return CustomerRecord(
      id: id,
      name: name,
      document: map['dni_ruc']?.toString().trim() ?? '',
      address: map['direccion']?.toString().trim() ?? '',
      documentType: optional(map['tipo_doc']),
      phone: optional(map['telefono']),
    );
  }
}
