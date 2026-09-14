import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

class EmpleadosState {
  final List<Map<String, dynamic>> empleados;
  final bool isLoading;

  EmpleadosState({this.empleados = const [], this.isLoading = true});
}

final empleadosNotifierProvider =
    StateNotifierProvider<EmpleadosNotifier, AsyncValue<EmpleadosState>>((ref) {
      return EmpleadosNotifier(ref.read(empleadosRepositoryProvider));
    });

class EmpleadosNotifier extends StateNotifier<AsyncValue<EmpleadosState>> {
  final EmpleadosRepository _repo;

  EmpleadosNotifier(this._repo) : super(const AsyncLoading()) {
    cargarEmpleados();
  }

  Future<void> cargarEmpleados({bool silent = false}) async {
    final previous = state.valueOrNull;
    if (!silent || previous == null) {
      state = const AsyncLoading();
    }

    try {
      final data = await _repo.obtenerEmpleados();
      final empleados = List<Map<String, dynamic>>.from(data);
      state = AsyncData(EmpleadosState(empleados: empleados, isLoading: false));
    } catch (e, st) {
      final safe = UserFacingException(ErrorMapper.map(e));
      if (silent && previous != null) {
        state = AsyncData(previous);
      } else {
        state = AsyncError(safe, st);
      }
    }
  }

  Future<String?> guardarEmpleado(
    Map<String, dynamic> data, {
    bool isEdit = false,
  }) async {
    try {
      final password = await _repo.guardarEmpleado(data, isEdit: isEdit);
      await cargarEmpleados(silent: true);
      return password;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> darDeBaja(int id) async {
    try {
      await _repo.darDeBajaEmpleado(id);
      await cargarEmpleados(silent: true);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> reactivar(int id) async {
    try {
      await _repo.reactivarEmpleado(id);
      await cargarEmpleados(silent: true);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> eliminarDefinitivamente(int id) async {
    try {
      await _repo.eliminarEmpleadoDefinitivamente(id);
      await cargarEmpleados(silent: true);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}

final busquedaEmpleadosProvider = StateProvider<String>((ref) => '');
final filtroActivosEmpleadosProvider = StateProvider<bool>((ref) => true);

final empleadosFiltradosProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final state = ref.watch(empleadosNotifierProvider);
  final busqueda = ref.watch(busquedaEmpleadosProvider).toLowerCase();
  final soloActivos = ref.watch(filtroActivosEmpleadosProvider);

  return state.maybeWhen(
    data: (st) {
      return st.empleados.where((e) {
        final activo = e['activo'] == true;
        if (soloActivos && !activo) return false;
        if (!soloActivos && activo) return false;

        if (busqueda.isNotEmpty) {
          final nombre = (e['nombre'] ?? '').toString().toLowerCase();
          final email = (e['email'] ?? '').toString().toLowerCase();
          return nombre.contains(busqueda) || email.contains(busqueda);
        }
        return true;
      }).toList();
    },
    orElse: () => [],
  );
});
