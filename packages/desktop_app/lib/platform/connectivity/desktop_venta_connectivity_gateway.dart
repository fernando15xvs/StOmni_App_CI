import 'dart:async';
import 'dart:io';

import 'package:core_logic/core_logic.dart';

/// Adaptador de conectividad exclusivo del cliente desktop.
///
/// El core sólo conoce [VentaConnectivityGateway]. Una caída de DNS/red se
/// interpreta como ausencia de conexión para que Ticket Interno pueda usar la
/// misma cola offline compartida que móvil.
class DesktopVentaConnectivityGateway implements VentaConnectivityGateway {
  const DesktopVentaConnectivityGateway();

  @override
  Future<bool> hasConnection() async {
    try {
      final addresses = await InternetAddress.lookup(
        'supabase.com',
      ).timeout(const Duration(seconds: 3));
      return addresses.isNotEmpty && addresses.any((address) => address.rawAddress.isNotEmpty);
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }
}
