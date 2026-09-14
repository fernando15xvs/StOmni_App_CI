import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

// Provider seguro para manejar el rol (reemplaza a la variable global insegura).
final rolProvider = StateProvider<String>((ref) => 'sin_rol');

/// Compatibilidad temporal para callers existentes.
/// La fuente de verdad de roles vive en [AppRoles].
String? normalizarRolApp(String? value) => AppRoles.normalize(value);

enum AuthRevalidationResult { valid, unavailable, denied }

class AuthState {
  const AuthState({
    this.isLoading = false,
    this.error,
    this.sessionStatus = SessionValidationStatus.signedOut,
  });

  final bool isLoading;
  final String? error;
  final SessionValidationStatus sessionStatus;

  bool get requiresPasswordChange =>
      sessionStatus == SessionValidationStatus.passwordChangeRequired;

  bool get requiresOrganizationSetup =>
      sessionStatus == SessionValidationStatus.organizationSetupRequired;

  AuthState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    SessionValidationStatus? sessionStatus,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      sessionStatus: sessionStatus ?? this.sessionStatus,
    );
  }
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this.ref) : super(const AuthState());

  static const String _emailKey = 'saved_email';
  static const String _rememberKey = 'remember_user';
  static const Duration _authTimeout = Duration(seconds: 15);
  static const Duration _secondaryTimeout = Duration(seconds: 5);

  final Ref ref;

  Future<String?> loadSavedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(_rememberKey) ?? false;
    if (remember) return prefs.getString(_emailKey);
    return null;
  }

  Future<bool> loadRememberState() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberKey) ?? false;
  }

  void setExternalError(String message) {
    state = state.copyWith(isLoading: false, error: message);
  }

  void clearExternalError() {
    state = state.copyWith(clearError: true);
  }

  Future<bool> signIn(String emailInput, String password, bool remember) async {
    ConfiguracionService.clearActiveConfiguration();
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      sessionStatus: SessionValidationStatus.signedOut,
    );

    try {
      final finalEmail = AuthUtils.formatEmail(emailInput);
      final res = await Supabase.instance.client.auth
          .signInWithPassword(
            email: finalEmail,
            password: password.trim(),
          )
          .timeout(_authTimeout);

      final user = res.user;
      if (user == null) {
        state = state.copyWith(
          isLoading: false,
          error: 'No se pudo iniciar sesión. Inténtalo nuevamente.',
          sessionStatus: SessionValidationStatus.signedOut,
        );
        return false;
      }

      await _saveRememberPreference(finalEmail, remember);

      final validation = await ref
          .read(validateSessionUseCaseProvider)
          .execute(allowOffline: false);
      if (validation.authUserId != null && validation.authUserId != user.id) {
        await _safeSignOut(clearOfflineAuthorization: false);
        state = state.copyWith(
          isLoading: false,
          error: 'La sesión cambió durante el inicio. Inténtalo nuevamente.',
          sessionStatus: SessionValidationStatus.signedOut,
        );
        return false;
      }

      if (validation.status == SessionValidationStatus.passwordChangeRequired) {
        ref.read(rolProvider.notifier).state = 'sin_rol';
        state = state.copyWith(
          isLoading: false,
          clearError: true,
          sessionStatus: SessionValidationStatus.passwordChangeRequired,
        );
        return true;
      }

      if (validation.requiresOrganizationSetup) {
        // Autenticado, pero todavía sin tenant. No hay rol ni autorización
        // offline hasta que F8.1 cree la organización server-side.
        ref.read(rolProvider.notifier).state = 'sin_rol';
        state = state.copyWith(
          isLoading: false,
          clearError: true,
          sessionStatus: SessionValidationStatus.organizationSetupRequired,
        );
        return true;
      }

      if (!validation.isAuthorized ||
          validation.status != SessionValidationStatus.online) {
        await _safeSignOut(clearOfflineAuthorization: true);
        state = state.copyWith(
          isLoading: false,
          error: _validationMessage(validation.status),
          sessionStatus: SessionValidationStatus.signedOut,
        );
        return false;
      }

      ref.read(rolProvider.notifier).state = validation.role!;

      // La ficha laboral es opcional. Si existe, actualizamos último acceso sin
      // convertirla nuevamente en fuente de autorización.
      try {
        await Supabase.instance.client
            .from('empleados')
            .update({'ultimo_acceso': AppTime.nowIso()})
            .eq('auth_id', user.id)
            .timeout(_secondaryTimeout);
      } catch (_) {}

      await _postLoginSetup();

      state = state.copyWith(
        isLoading: false,
        clearError: true,
        sessionStatus: SessionValidationStatus.online,
      );
      return true;
    } on TimeoutException catch (error) {
      await _safeSignOut(clearOfflineAuthorization: false);
      state = state.copyWith(
        isLoading: false,
        error: ErrorMapper.map(error),
        sessionStatus: SessionValidationStatus.signedOut,
      );
      return false;
    } catch (error) {
      await _safeSignOut(clearOfflineAuthorization: false);
      state = state.copyWith(
        isLoading: false,
        error: ErrorMapper.map(error),
        sessionStatus: SessionValidationStatus.signedOut,
      );
      return false;
    }
  }

  Future<void> _saveRememberPreference(
    String finalEmail,
    bool remember,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (remember) {
        await prefs.setBool(_rememberKey, true);
        await prefs.setString(_emailKey, finalEmail);
      } else {
        await prefs.setBool(_rememberKey, false);
        await prefs.remove(_emailKey);
      }
    } catch (_) {}
  }

  /// El arranque de cualquier cliente usa el mismo motor sin reglas de splash.
  Future<SessionValidationResult> restoreSession() async {
    final result = await ref.read(validateSessionUseCaseProvider).execute();
    if (result.status == SessionValidationStatus.online) {
      try {
        await ref
            .read(businessProfileGatewayProvider)
            .load()
            .timeout(_secondaryTimeout);
      } catch (_) {
        // No autoriza ventas; sólo prepara una caché para el siguiente offline.
      }
    }
    if (result.authUserId != null &&
        ref.read(supabaseProvider).auth.currentUser?.id != result.authUserId) {
      return const SessionValidationResult(
        SessionValidationStatus.sessionChanged,
      );
    }
    _applySessionValidation(result, restoring: true);
    return result;
  }

  /// Después de crear la organización, exige autorización tenant online antes
  /// de permitir la entrada al dominio empresarial.
  Future<bool> finishOrganizationSetup() async {
    final result = await ref
        .read(validateSessionUseCaseProvider)
        .execute(allowOffline: false);
    if (result.status == SessionValidationStatus.online &&
        result.isAuthorized) {
      _applySessionValidation(result, restoring: false);
      await _postLoginSetup();
      return true;
    }

    if (result.status == SessionValidationStatus.unavailable ||
        result.status == SessionValidationStatus.failed ||
        result.status == SessionValidationStatus.offlineAuthorizationMissing) {
      state = state.copyWith(
        isLoading: false,
        error: _validationMessage(result.status),
      );
      return false;
    }

    _applySessionValidation(result, restoring: false);
    return false;
  }

  /// Sincronizar exige autorización online; un caché vigente no la sustituye.
  Future<AuthRevalidationResult> revalidateCurrentSession() async {
    final result = await ref
        .read(validateSessionUseCaseProvider)
        .execute(allowOffline: false);
    _applySessionValidation(result, restoring: false);
    return switch (result.status) {
      SessionValidationStatus.online => AuthRevalidationResult.valid,
      SessionValidationStatus.denied ||
      SessionValidationStatus.signedOut ||
      SessionValidationStatus.passwordChangeRequired ||
      SessionValidationStatus.organizationSetupRequired =>
        AuthRevalidationResult.denied,
      _ => AuthRevalidationResult.unavailable,
    };
  }

  void _applySessionValidation(
    SessionValidationResult result, {
    required bool restoring,
  }) {
    if (result.status == SessionValidationStatus.sessionChanged) return;
    if (result.isAuthorized) {
      if (ref.read(supabaseProvider).auth.currentUser?.id !=
          result.authUserId) {
        return;
      }
      ref.read(rolProvider.notifier).state = result.role!;
      state = state.copyWith(
        clearError: true,
        sessionStatus: result.status,
      );
      return;
    }

    final shouldClearRole =
        restoring ||
        result.status == SessionValidationStatus.denied ||
        result.status == SessionValidationStatus.signedOut ||
        result.status == SessionValidationStatus.passwordChangeRequired ||
        result.status == SessionValidationStatus.organizationSetupRequired;
    if (shouldClearRole) {
      ref.read(rolProvider.notifier).state = 'sin_rol';
      ConfiguracionService.clearActiveConfiguration();
    }
    final message = _validationMessage(result.status);
    state = state.copyWith(
      isLoading: false,
      error: message,
      clearError: message == null,
      sessionStatus: result.status,
    );
  }

  String? _validationMessage(SessionValidationStatus status) => switch (status) {
    SessionValidationStatus.denied =>
      'Tu cuenta ya no tiene acceso activo. Comunícate con el administrador.',
    SessionValidationStatus.offlineAuthorizationMissing =>
      'No hay conexión y este dispositivo todavía no tiene una autorización '
          'offline vigente para tu cuenta. Conéctate e inicia sesión nuevamente.',
    SessionValidationStatus.unavailable => ErrorMapper.connectionMessage,
    SessionValidationStatus.passwordChangeRequired =>
      'Inicia sesión y cambia tu contraseña antes de continuar.',
    SessionValidationStatus.failed =>
      'No pudimos validar tu acceso. Inténtalo nuevamente.',
    _ => null,
  };

  Future<void> _postLoginSetup() async {
    try {
      await ref
          .read(businessProfileGatewayProvider)
          .load()
          .timeout(_secondaryTimeout);
    } catch (_) {
      // No impide iniciar sesión; cada operación validará las capacidades.
    }
    try {
      await ConfiguracionService.cargarNegocio().timeout(_secondaryTimeout);
    } catch (_) {
      // La configuración también se intenta cargar al arrancar la app.
    }
  }

  Future<void> _safeSignOut({required bool clearOfflineAuthorization}) async {
    if (clearOfflineAuthorization) {
      try {
        await AuthSessionCache.clear();
      } catch (_) {}
    }
    ConfiguracionService.clearActiveConfiguration();
    ref.read(rolProvider.notifier).state = 'sin_rol';
    try {
      await Supabase.instance.client.auth
          .signOut(scope: SignOutScope.local)
          .timeout(_secondaryTimeout);
    } catch (_) {}
  }

  Future<void> signOut() async {
    await _safeSignOut(clearOfflineAuthorization: true);
    state = const AuthState();
  }

  Future<bool> cambiarPassword(String newPassword) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await Supabase.instance.client.auth
          .updateUser(
            UserAttributes(
              password: newPassword,
              data: {'force_password_change': false},
            ),
          )
          .timeout(_authTimeout);
      final result = await ref
          .read(validateSessionUseCaseProvider)
          .execute(allowOffline: false);
      _applySessionValidation(result, restoring: false);
      state = state.copyWith(isLoading: false, clearError: true);
      return true;
    } on TimeoutException catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMapper.map(error),
      );
      return false;
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMapper.map(error),
      );
      return false;
    }
  }
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) => AuthController(ref),
);
