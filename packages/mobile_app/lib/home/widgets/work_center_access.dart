import 'package:core_logic/business/application/business_module_policy.dart';
import 'package:core_logic/business/domain/business_profile.dart';

/// Navigation remains fail-closed before the business profile is loaded.
/// Permissions for each destination continue to be enforced by its screen
/// and on the backend. Visibility does not grant access.
class WorkCenterAccess {
  const WorkCenterAccess._();

  static bool enabled(
    BusinessCapabilities? capabilities,
    BusinessModule module,
  ) {
    return capabilities != null &&
        BusinessModulePolicy.isEnabled(capabilities, module);
  }
}
