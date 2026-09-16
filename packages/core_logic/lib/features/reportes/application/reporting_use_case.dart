import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../errors/user_facing_exception.dart';

enum FinancialMovementType { income, expense }

class FinancialMovementRecord {
  const FinancialMovementRecord({
    required this.type,
    required this.amount,
    required this.description,
    required this.date,
    this.saleId,
    this.expenseId,
    this.employeePaymentId,
    this.paymentMethod,
  });

  final FinancialMovementType type;
  final double amount;
  final String description;
  final DateTime date;
  final int? saleId;
  final int? expenseId;
  final int? employeePaymentId;
  final String? paymentMethod;
}

class InventoryMovementRecord {
  const InventoryMovementRecord({
    required this.productId,
    required this.productName,
    required this.warehouseName,
    required this.movementType,
    required this.date,
    required this.quantity,
    required this.entryQuantity,
    required this.exitQuantity,
    this.observations,
    this.unitLabel,
    this.saleUnitType,
    this.saleUnitTypeSnapshot,
    this.baseUnitSnapshot,
    this.unitsPerPackage,
    this.unitsPerPackageSnapshot,
  });

  final int productId;
  final String productName;
  final String warehouseName;
  final String movementType;
  final DateTime date;
  final double quantity;
  final double entryQuantity;
  final double exitQuantity;
  final String? observations;
  final String? unitLabel;
  final String? saleUnitType;
  final String? saleUnitTypeSnapshot;
  final String? baseUnitSnapshot;
  final int? unitsPerPackage;
  final int? unitsPerPackageSnapshot;

  bool get isEntry => entryQuantity > 0 || (entryQuantity == 0 && quantity > 0);
}

class ReportingSnapshot {
  ReportingSnapshot({
    required Iterable<FinancialMovementRecord> financialMovements,
    required Iterable<InventoryMovementRecord> inventoryMovements,
    required this.totalDiscounts,
  }) : financialMovements = List<FinancialMovementRecord>.unmodifiable(
         financialMovements,
       ),
       inventoryMovements = List<InventoryMovementRecord>.unmodifiable(
         inventoryMovements,
       );

  final List<FinancialMovementRecord> financialMovements;
  final List<InventoryMovementRecord> inventoryMovements;
  final double totalDiscounts;

  double get income => financialMovements
      .where((movement) => movement.type == FinancialMovementType.income)
      .fold(0, (total, movement) => total + movement.amount);

  double get expenses => financialMovements
      .where((movement) => movement.type == FinancialMovementType.expense)
      .fold(0, (total, movement) => total + movement.amount);

  double get netCashFlow => income - expenses;
}

abstract interface class ReportingGateway {
  Future<ReportingSnapshot> loadPeriod({
    required DateTime start,
    required DateTime end,
  });
}

class LoadReportingSnapshotUseCase {
  const LoadReportingSnapshotUseCase({
    required ReportingGateway gateway,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _authorizer = authorizer;

  final ReportingGateway _gateway;
  final OperationAuthorizer _authorizer;

  Future<ReportingSnapshot> execute({
    required DateTime start,
    required DateTime end,
  }) async {
    if (end.isBefore(start)) {
      throw ArgumentError(
        'El fin del periodo no puede ser anterior al inicio.',
      );
    }
    final authorizedUser = await _authorizer.require({
      AppPermission.reportsViewProfit,
    });
    final snapshot = await _gateway.loadPeriod(start: start, end: end);
    if (_authorizer.currentAuthUserId != authorizedUser) {
      throw const UserFacingException(
        'La sesión cambió mientras se cargaban los reportes.',
      );
    }
    return snapshot;
  }
}
