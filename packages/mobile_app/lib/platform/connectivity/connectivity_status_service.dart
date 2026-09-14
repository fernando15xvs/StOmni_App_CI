import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Adaptador de plataforma para consultar el estado de red del dispositivo.
///
/// La conectividad no forma parte del dominio: mobile_app la detecta y entrega
/// el resultado a los casos de uso de core_logic mediante sus puertos.
class ConnectivityStatusService {
  const ConnectivityStatusService._();

  static Future<bool> hasInternet() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.isNotEmpty &&
          result.any((item) => item != ConnectivityResult.none);
    } catch (error) {
      debugPrint('No se pudo consultar la conectividad: $error');
      return false;
    }
  }
}
