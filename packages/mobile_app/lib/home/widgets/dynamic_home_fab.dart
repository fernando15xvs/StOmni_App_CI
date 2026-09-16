import 'package:mobile_app/platform/connectivity/connectivity_status_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/navigation_utils.dart';
import 'package:core_logic/core_logic.dart';
import '../../features/almacen/pages/ingreso_mercaderia_page.dart';
import '../../features/almacen/pages/nuevo_producto_page.dart';
import '../../features/gastos/pages/nuevo_gasto_page.dart';
import '../../features/ventas/pages/seleccion_productos_page.dart';
import '../controllers/home_controller.dart';
import 'glass_fab.dart';

class DynamicHomeFab extends ConsumerWidget {
  const DynamicHomeFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = ref.watch(homeTabProvider);
    final canCreateProducts = ref
        .watch(appPermissionsProvider)
        .contains(AppPermission.productsCreate);

    if (currentIndex == 1) {
      if (MediaQuery.of(context).size.width > 800) {
        return const SizedBox.shrink();
      }
      return Row(
        children: [
          Expanded(
            child: GlassFab(
              onPressed: () async {
                await AppNavigator.navegarA(
                  context,
                  const SeleccionProductosV2(),
                );
                ref.read(homeRefreshRevisionProvider.notifier).state++;
              },
              baseColor: Theme.of(context).colorScheme.primary,
              icon: Icons.add_shopping_cart,
              label: 'VENTA',
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: GlassFab(
              onPressed: () async {
                FocusScope.of(context).unfocus();
                await AppNavigator.navegarA(context, const NuevoGastoPage());
                ref.read(homeRefreshRevisionProvider.notifier).state++;
              },
              baseColor: Colors.red[700]!,
              icon: Icons.remove_circle_outline,
              label: 'GASTO',
            ),
          ),
        ],
      );
    }

    if (currentIndex == 2) {
      Future<void> abrirIngreso() async {
        FocusManager.instance.primaryFocus?.unfocus();
        final online = await ConnectivityStatusService.hasInternet();
        if (!context.mounted) return;
        if (!online) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Requiere conexión a Internet'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        await AppNavigator.navegarA(context, const IngresoMercaderiaPage());
        ref.read(homeRefreshRevisionProvider.notifier).state++;
      }

      final botonIngreso = Expanded(
        child: GlassFab(
          onPressed: abrirIngreso,
          baseColor: Colors.black,
          icon: Icons.move_to_inbox,
          label: 'INGRESO PROD.',
        ),
      );

      if (MediaQuery.of(context).size.width > 800) {
        return const SizedBox.shrink();
      }

      if (!canCreateProducts) {
        return Row(children: [botonIngreso]);
      }

      return Row(
        children: [
          botonIngreso,
          const SizedBox(width: 15),
          Expanded(
            child: GlassFab(
              onPressed: () async {
                FocusManager.instance.primaryFocus?.unfocus();
                final online = await ConnectivityStatusService.hasInternet();
                if (!context.mounted) return;
                if (!online) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Requiere conexión a Internet'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                await AppNavigator.navegarA(context, const NuevoProductoPage());
                ref.read(homeRefreshRevisionProvider.notifier).state++;
              },
              baseColor: Theme.of(context).colorScheme.primary,
              icon: Icons.add,
              label: 'REGISTRO PROD.',
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
