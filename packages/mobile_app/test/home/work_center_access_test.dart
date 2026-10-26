import 'package:core_logic/business/application/business_module_policy.dart';
import 'package:core_logic/business/domain/business_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/home/widgets/work_center_access.dart';

void main() {
  test('Centro oculta capacidades opcionales hasta cargar el perfil', () {
    expect(
      WorkCenterAccess.enabled(null, BusinessModule.electronicDocuments),
      isFalse,
    );
    expect(WorkCenterAccess.enabled(null, BusinessModule.inventory), isFalse);
  });

  test('Facturación electrónica apagada oculta Documentos', () {
    const capabilities = BusinessCapabilities(electronicInvoicing: false);
    expect(
      WorkCenterAccess.enabled(
        capabilities,
        BusinessModule.electronicDocuments,
      ),
      isFalse,
    );
    expect(
      WorkCenterAccess.enabled(capabilities, BusinessModule.customers),
      isTrue,
    );
  });

  test('Sin inventario no se ofrece Kardex por Centro', () {
    const capabilities = BusinessCapabilities(
      inventoryEnabled: false,
      multipleWarehouses: false,
      supplierManagement: false,
    );
    expect(
      WorkCenterAccess.enabled(capabilities, BusinessModule.inventory),
      isFalse,
    );
    expect(
      WorkCenterAccess.enabled(capabilities, BusinessModule.suppliers),
      isFalse,
    );
  });

  test('Capacidades activas permanecen disponibles', () {
    const capabilities = BusinessCapabilities();
    expect(
      WorkCenterAccess.enabled(
        capabilities,
        BusinessModule.electronicDocuments,
      ),
      isTrue,
    );
    expect(
      WorkCenterAccess.enabled(capabilities, BusinessModule.inventory),
      isTrue,
    );
  });
}
