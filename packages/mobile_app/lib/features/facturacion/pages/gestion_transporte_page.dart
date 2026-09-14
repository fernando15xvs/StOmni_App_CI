import 'package:flutter/material.dart';

import '../widgets/gestion_transporte/transporte_privado_tab.dart';
import '../widgets/gestion_transporte/transporte_publico_tab.dart';

class GestionTransportePage extends StatelessWidget {
  const GestionTransportePage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final brandColor = isDark
        ? const Color(0xFF8E24AA)
        : const Color(0xFF6A1B9A);
    final bgColor = isDark ? const Color(0xFF121212) : const Color(0xFFF3F4F6);

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(
          context,
        ).colorScheme.copyWith(primary: brandColor),
      ),
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            backgroundColor: brandColor,
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text(
              'Transporte',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            bottom: const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              tabs: [
                Tab(
                  text: 'Transporte Privado',
                  icon: Icon(Icons.directions_car),
                ),
                Tab(text: 'Transporte Público', icon: Icon(Icons.business)),
              ],
            ),
          ),
          body: const TabBarView(
            children: [TransportePrivadoTab(), TransportePublicoTab()],
          ),
        ),
      ),
    );
  }
}
