import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/inventory_use_case_providers.dart';

class AlmacenAdminNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> build() => _cargar();

  Future<List<Map<String, dynamic>>> _cargar() async {
    final records = await ref
        .read(warehouseAdminUseCaseProvider)
        .listWarehouses();
    return records
        .map(
          (warehouse) => <String, dynamic>{
            'id': warehouse.id,
            'nombre': warehouse.name,
            'activo': warehouse.active,
            'direccion': warehouse.address,
            'ubigeo': warehouse.ubigeo,
            'departamento': warehouse.department,
            'provincia': warehouse.province,
            'distrito': warehouse.district,
            'cod_local': warehouse.localCode,
            'referencia': warehouse.reference,
          },
        )
        .toList(growable: false);
  }

  Future<void> recargar() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_cargar);
  }

  Future<void> guardar({
    int? id,
    required String nombre,
    required String direccion,
    required String ubigeo,
    required String departamento,
    required String provincia,
    required String distrito,
    required String codLocal,
    required String referencia,
  }) async {
    await ref
        .read(warehouseAdminUseCaseProvider)
        .save(
          SaveWarehouseCommand(
            id: id,
            name: nombre,
            address: direccion,
            ubigeo: ubigeo,
            department: departamento,
            province: provincia,
            district: distrito,
            localCode: codLocal,
            reference: referencia,
          ),
        );
    await recargar();
  }

  Future<void> desactivar(int id) async {
    await ref.read(warehouseAdminUseCaseProvider).deactivate(id);
    await recargar();
  }

  Future<void> reactivar(int id) async {
    await ref.read(warehouseAdminUseCaseProvider).reactivate(id);
    await recargar();
  }
}

final almacenAdminNotifierProvider =
    AsyncNotifierProvider<AlmacenAdminNotifier, List<Map<String, dynamic>>>(
      AlmacenAdminNotifier.new,
    );
