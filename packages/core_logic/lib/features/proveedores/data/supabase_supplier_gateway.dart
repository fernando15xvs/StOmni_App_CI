import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/supplier_use_case.dart';

class SupabaseSupplierGateway implements SupplierGateway {
  const SupabaseSupplierGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<SupplierRecord>> list({
    String query = '',
    bool activeOnly = false,
  }) async {
    var request = client.from('proveedores').select();
    if (activeOnly) {
      request = request.eq('estado', 'activo').eq('activo', true);
    }
    final text = query.trim();
    if (text.isNotEmpty) {
      request = request.or('nombre.ilike.%$text%,ruc.ilike.%$text%');
    }
    final rows = await request.order('nombre');
    return rows.map(_decode).toList(growable: false);
  }

  @override
  Future<bool> documentExists(String document, {int? excludingId}) async {
    final value = document.trim();
    if (value.isEmpty) return false;
    var request = client.from('proveedores').select('id').eq('ruc', value);
    if (excludingId != null) request = request.neq('id', excludingId);
    return await request.limit(1).maybeSingle() != null;
  }

  @override
  Future<SupplierRecord> save(SupplierDraft draft, {int? id}) async {
    final payload = <String, dynamic>{
      'nombre': draft.name,
      'ruc': draft.document,
      'estado': draft.active ? 'activo' : 'inactivo',
      'activo': draft.active,
      if (draft.documentType != null && draft.documentType!.isNotEmpty)
        'tipo_doc': draft.documentType,
      if (draft.phone != null) 'telefono': draft.phone,
      if (draft.address != null) 'direccion': draft.address,
    };
    final Object? raw;
    if (id == null) {
      raw = await client.from('proveedores').insert(payload).select().single();
    } else {
      raw = await client
          .from('proveedores')
          .update(payload)
          .eq('id', id)
          .select()
          .single();
    }
    return _decode(raw);
  }

  @override
  Future<void> deactivate(int id) async {
    await client
        .from('proveedores')
        .update({'estado': 'inactivo', 'activo': false})
        .eq('id', id);
  }

  SupplierRecord _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Registro de proveedor inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final rawId = map['id'];
    final id = rawId is num
        ? rawId.toInt()
        : int.tryParse(rawId?.toString() ?? '');
    final name = map['nombre']?.toString().trim() ?? '';
    if (id == null || id <= 0 || name.isEmpty) {
      throw const FormatException('El proveedor no tiene id o nombre válido.');
    }
    String? optional(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    final status = map['estado']?.toString().trim().toLowerCase();
    return SupplierRecord(
      id: id,
      name: name,
      document: map['ruc']?.toString().trim() ?? '',
      active: map['activo'] != false && status != 'inactivo',
      documentType: optional(map['tipo_doc']),
      phone: optional(map['telefono']),
      address: optional(map['direccion']),
    );
  }
}
