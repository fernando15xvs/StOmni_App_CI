import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/preferences_service.dart';

class PreferencesState {
  final String themeMode;
  final int startScreen;
  final String ticketSize;

  PreferencesState({
    required this.themeMode,
    required this.startScreen,
    required this.ticketSize,
  });

  PreferencesState copyWith({
    String? themeMode,
    int? startScreen,
    String? ticketSize,
  }) {
    return PreferencesState(
      themeMode: themeMode ?? this.themeMode,
      startScreen: startScreen ?? this.startScreen,
      ticketSize: ticketSize ?? this.ticketSize,
    );
  }
}

class PreferencesNotifier extends StateNotifier<PreferencesState> {
  PreferencesNotifier()
    : super(
        PreferencesState(
          themeMode: PreferencesService.themeMode,
          startScreen: PreferencesService.startScreen,
          ticketSize: PreferencesService.ticketSize,
        ),
      );

  Future<void> setThemeMode(String mode) async {
    await PreferencesService.setThemeMode(mode);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setStartScreen(int index) async {
    await PreferencesService.setStartScreen(index);
    state = state.copyWith(startScreen: index);
  }

  Future<void> setTicketSize(String size) async {
    await PreferencesService.setTicketSize(size);
    state = state.copyWith(ticketSize: size);
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, PreferencesState>((ref) {
      return PreferencesNotifier();
    });
