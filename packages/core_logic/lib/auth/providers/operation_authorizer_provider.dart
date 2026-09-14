import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/operation_authorizer.dart';
import '../controllers/auth_controller.dart';
import '../domain/app_permission.dart';
import 'session_validation_provider.dart';

final operationAuthorizerProvider = Provider<OperationAuthorizer>((ref) =>
    SessionOperationAuthorizer(ref.watch(validateSessionUseCaseProvider)));

/// Solo visibilidad de UI. Los casos de uso validan sesión y permisos otra vez;
/// PostgreSQL conserva la autoridad final sobre cada escritura.
final appPermissionsProvider = Provider<Set<AppPermission>>((ref) =>
    RolePermissionPolicy.forRole(ref.watch(rolProvider)));
