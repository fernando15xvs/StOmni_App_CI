import 'package:flutter/material.dart';
import 'app_styles.dart';

/// Botón primario reutilizable
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Color? backgroundColor;
  final double width;
  final double height;

  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.isLoading = false,
    this.backgroundColor,
    this.width = double.infinity,
    this.height = 55,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: AppStyles.primaryButtonStyle(backgroundColor: backgroundColor),
        child: isLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}

/// Botón peligroso (rojo) reutilizable
class DangerButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double width;
  final double height;

  const DangerButton({
    super.key,
    required this.label,
    this.onPressed,
    this.width = double.infinity,
    this.height = 48,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        onPressed: onPressed,
        style: AppStyles.dangerButtonStyle(),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Card estándar con decoración reutilizable
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? backgroundColor;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: AppStyles.cardDecoration(backgroundColor: backgroundColor),
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Sección con título y contenido
class AppSection extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AppSection({
    super.key,
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(title, style: AppStyles.titleMedium),
        ),
        AppStyles.verticalSmall,
        Padding(padding: padding, child: child),
      ],
    );
  }
}

/// Loading spinner estándar
class AppLoadingSpinner extends StatelessWidget {
  final String? message;

  const AppLoadingSpinner({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: AppStyles.primaryGreen),
          if (message != null) ...[
            AppStyles.verticalMedium,
            Text(message!, style: AppStyles.subtitleText),
          ],
        ],
      ),
    );
  }
}

/// Error message display
class AppErrorMessage extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const AppErrorMessage({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: AppStyles.primaryRed,
          ),
          AppStyles.verticalMedium,
          Text(
            'Error',
            style: AppStyles.titleMedium.copyWith(color: AppStyles.primaryRed),
          ),
          AppStyles.verticalSmall,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppStyles.subtitleText,
            ),
          ),
          if (onRetry != null) ...[
            AppStyles.verticalMedium,
            ElevatedButton(
              onPressed: onRetry,
              style: AppStyles.primaryButtonStyle(),
              child: const Text('Reintentar'),
            ),
          ],
        ],
      ),
    );
  }
}
