import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // --- Theme Mode ---
  static String get themeMode => _prefs.getString('themeMode') ?? 'system';
  static Future<void> setThemeMode(String value) async {
    await _prefs.setString('themeMode', value);
  }

  // --- Start Screen ---
  // 0: Dashboard, 1: Punto de Venta, 2: Inventario
  static int get startScreen => _prefs.getInt('startScreen') ?? 0;
  static Future<void> setStartScreen(int value) async {
    await _prefs.setInt('startScreen', value);
  }

  // --- Ticket Size ---
  // '58mm', '80mm', 'a4'
  static String get ticketSize => _prefs.getString('ticketSize') ?? '80mm';
  static Future<void> setTicketSize(String value) async {
    await _prefs.setString('ticketSize', value);
  }

  // --- Notification permission explanation ---
  static bool get notificationPermissionExplanationSeen =>
      _prefs.getBool('notificationPermissionExplanationSeen') ?? false;

  static Future<void> setNotificationPermissionExplanationSeen(
    bool value,
  ) async {
    await _prefs.setBool('notificationPermissionExplanationSeen', value);
  }
}
