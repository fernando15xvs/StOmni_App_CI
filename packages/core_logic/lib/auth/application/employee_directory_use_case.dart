class EmployeeDirectoryRecord {
  const EmployeeDirectoryRecord({
    required this.id,
    required this.name,
    required this.role,
    required this.active,
    this.email,
    this.position,
  });

  final int id;
  final String name;
  final String role;
  final bool active;
  final String? email;
  final String? position;
}

abstract interface class EmployeeDirectoryGateway {
  Future<List<EmployeeDirectoryRecord>> list({bool includeInactive = true});
}

class EmployeeDirectoryUseCase {
  const EmployeeDirectoryUseCase(this._gateway);

  final EmployeeDirectoryGateway _gateway;

  Future<List<EmployeeDirectoryRecord>> list({bool includeInactive = true}) =>
      _gateway.list(includeInactive: includeInactive);
}
