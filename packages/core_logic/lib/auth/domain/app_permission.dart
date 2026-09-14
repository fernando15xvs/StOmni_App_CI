import '../../constants/app_roles.dart';

enum AppPermission {
  productsCreate('products.create'),
  productsUpdate('products.update'),
  productsChangePrice('products.change_price'),
  inventoryReceive('inventory.receive'),
  inventoryAdjust('inventory.adjust'),
  salesCreate('sales.create'),
  salesDiscount('sales.discount'),
  purchasesManage('purchases.manage'),
  reportsViewProfit('reports.view_profit'),
  businessConfigure('business.configure');

  const AppPermission(this.code);
  final String code;

  static AppPermission? fromCode(String? value) {
    final code = value?.trim();
    if (code == null || code.isEmpty) return null;
    for (final permission in values) {
      if (permission.code == code) return permission;
    }
    return null;
  }

  static Set<AppPermission> decodeCodes(Iterable<Object?> codes) {
    final result = <AppPermission>{};
    for (final raw in codes) {
      final permission = fromCode(raw?.toString());
      if (permission == null) {
        throw FormatException('Permiso desconocido: ${raw?.toString() ?? ''}');
      }
      result.add(permission);
    }
    return Set<AppPermission>.unmodifiable(result);
  }
}

/// Matriz base. Los overrides por empleado sólo pueden restringir estos
/// permisos; nunca conceder capacidades que el rol no poseía.
class RolePermissionPolicy {
  const RolePermissionPolicy._();

  static Set<AppPermission> forRole(String? role) => switch (AppRoles.normalize(role)) {
    AppRoles.admin => Set<AppPermission>.unmodifiable(AppPermission.values),
    AppRoles.operador => const {
      AppPermission.inventoryReceive,
      AppPermission.salesCreate,
      AppPermission.salesDiscount,
    },
    _ => const {},
  };

  static bool allows(String? role, AppPermission permission) =>
      forRole(role).contains(permission);
}
