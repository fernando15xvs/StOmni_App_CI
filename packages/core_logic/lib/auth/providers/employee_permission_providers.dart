import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/manage_employee_permissions_use_case.dart';
import '../data/supabase_employee_permission_gateway.dart';

final employeePermissionGatewayProvider = Provider<EmployeePermissionGateway>(
  (ref) => SupabaseEmployeePermissionGateway(ref.watch(supabaseProvider)),
);

final manageEmployeePermissionsUseCaseProvider =
    Provider<ManageEmployeePermissionsUseCase>(
      (ref) => ManageEmployeePermissionsUseCase(
        ref.watch(employeePermissionGatewayProvider),
      ),
    );
