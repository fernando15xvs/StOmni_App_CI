import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';

class GlobalDateFilterState {
  String filtroTipo;
  DateTime fechaEspecifica;
  DateTimeRange? rangoPersonalizado;

  GlobalDateFilterState({
    this.filtroTipo = 'Diario',
    DateTime? fechaEspecifica,
    this.rangoPersonalizado,
  }) : fechaEspecifica = fechaEspecifica ?? AppTime.today();

  DateTime get fechaInicio {
    final base = filtroTipo == 'Diario' ? fechaEspecifica : AppTime.now();
    switch (filtroTipo) {
      case 'Diario':
        return DateTime(base.year, base.month, base.day);
      case 'Semanal':
        return DateTime(
          base.year,
          base.month,
          base.day,
        ).subtract(Duration(days: base.weekday - 1));
      case 'Mensual':
        return DateTime(base.year, base.month, 1);
      case 'Anual':
        return DateTime(base.year, 1, 1);
      case 'Personalizado':
        return rangoPersonalizado?.start ?? base;
      default:
        return base;
    }
  }

  DateTime get fechaFin {
    final base = filtroTipo == 'Diario' ? fechaEspecifica : AppTime.now();

    if (filtroTipo == 'Personalizado') {
      final end = rangoPersonalizado?.end ?? base;

      // El DateRangePicker entrega el último día a las 00:00.
      // Lo normalizamos al último segundo del día seleccionado.
      return DateTime(end.year, end.month, end.day, 23, 59, 59);
    }

    if (filtroTipo == 'Diario') {
      return DateTime(base.year, base.month, base.day, 23, 59, 59);
    }

    return base;
  }

  String get textoFechaBase {
    if (filtroTipo == 'Diario') {
      return "Día: ${DateFormat('dd MMMM', 'es').format(fechaEspecifica)}";
    }
    return filtroTipo;
  }
}

class GlobalDateFilterWidget {
  /// Retorna el widget de título que muestra la fecha actual (ej. para AppBar title)
  static Widget buildTitleWidget({
    required GlobalDateFilterState filterState,
    required VoidCallback onSelectFechaEspecifica,
  }) {
    return Builder(
      builder: (context) {
        final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
        if (filterState.filtroTipo != 'Diario') {
          return Text(
            filterState.filtroTipo,
            style: TextStyle(color: secondary, fontSize: 13),
          );
        }
        return GestureDetector(
          onTap: onSelectFechaEspecifica,
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filterState.textoFechaBase,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 5),
                Icon(Icons.date_range_rounded, color: secondary, size: 14),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Retorna el DropdownButton estilizado para pantallas grandes
  static Widget buildDropdownFilter({
    required BuildContext context,
    required GlobalDateFilterState filterState,
    required Color primaryColor,
    required Function(String) onChanged,
    required VoidCallback onSelectRango,
  }) {
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      padding: const EdgeInsets.only(left: 14, right: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Theme(
        data: Theme.of(
          context,
        ).copyWith(canvasColor: Theme.of(context).cardColor),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: filterState.filtroTipo == 'Personalizado'
                ? null
                : filterState.filtroTipo,
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
            items: [
              'Diario',
              'Semanal',
              'Mensual',
              'Anual',
              'Personalizado',
            ].map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
            onChanged: (val) {
              if (val == 'Personalizado') {
                onSelectRango();
              } else if (val != null) {
                onChanged(val);
              }
            },
          ),
        ),
      ),
    );
  }

  /// Helper functions para mostrar los pickers
  static Future<void> seleccionarFechaEspecifica({
    required BuildContext context,
    required GlobalDateFilterState filterState,
    required Color primaryColor,
    required Function(DateTime) onSelected,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: filterState.fechaEspecifica,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      locale: const Locale('es', 'ES'),
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: ColorScheme.light(primary: primaryColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      onSelected(picked);
    }
  }

  static Future<void> seleccionarRango({
    required BuildContext context,
    required Color primaryColor,
    required Function(DateTimeRange) onSelected,
  }) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      locale: const Locale('es', 'ES'),
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: ColorScheme.light(primary: primaryColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      onSelected(picked);
    }
  }
}
