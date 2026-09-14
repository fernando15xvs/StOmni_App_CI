class WarehouseAdminRecord {
  const WarehouseAdminRecord({
    required this.id,
    required this.name,
    required this.active,
    this.address,
    this.ubigeo,
    this.department,
    this.province,
    this.district,
    this.localCode = '0000',
    this.reference,
  });

  final int id;
  final String name;
  final bool active;
  final String? address;
  final String? ubigeo;
  final String? department;
  final String? province;
  final String? district;
  final String localCode;
  final String? reference;

  bool get hasGreLocation {
    final normalizedAddress = address?.trim() ?? '';
    final normalizedUbigeo = ubigeo?.trim() ?? '';
    return normalizedAddress.isNotEmpty &&
        RegExp(r'^[0-9]{6}$').hasMatch(normalizedUbigeo);
  }
}

abstract interface class WarehouseAdminGateway {
  Future<List<WarehouseAdminRecord>> listWarehouses();

  Future<void> save({
    int? id,
    required String name,
    required String address,
    required String ubigeo,
    required String department,
    required String province,
    required String district,
    required String localCode,
    required String reference,
  });

  Future<void> deactivate(int id);

  Future<void> reactivate(int id);
}

class SaveWarehouseCommand {
  const SaveWarehouseCommand({
    this.id,
    required this.name,
    required this.address,
    required this.ubigeo,
    required this.department,
    required this.province,
    required this.district,
    required this.localCode,
    required this.reference,
  });

  final int? id;
  final String name;
  final String address;
  final String ubigeo;
  final String department;
  final String province;
  final String district;
  final String localCode;
  final String reference;
}

class WarehouseAdminUseCase {
  const WarehouseAdminUseCase(this._gateway);

  final WarehouseAdminGateway _gateway;

  Future<List<WarehouseAdminRecord>> listWarehouses() =>
      _gateway.listWarehouses();

  Future<void> save(SaveWarehouseCommand command) => _gateway.save(
    id: command.id,
    name: command.name,
    address: command.address,
    ubigeo: command.ubigeo,
    department: command.department,
    province: command.province,
    district: command.district,
    localCode: command.localCode,
    reference: command.reference,
  );

  Future<void> deactivate(int id) => _gateway.deactivate(id);

  Future<void> reactivate(int id) => _gateway.reactivate(id);
}
