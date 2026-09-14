import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class PostLoginLoadingOverlay extends StatefulWidget {
  const PostLoginLoadingOverlay({super.key});

  @override
  State<PostLoginLoadingOverlay> createState() =>
      _PostLoginLoadingOverlayState();
}

class _PostLoginLoadingOverlayState extends State<PostLoginLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glowAnimation;
  late final Animation<double> _iconScaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _glowAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _iconScaleAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    if (reduceMotion) {
      _controller.stop();
      // Centro de ambos tweens: escala neutra 1.0.
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final primary = theme.colorScheme.primary;
    final bgColor = theme.scaffoldBackgroundColor;
    final textColor = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurfaceVariant;

    final title = Text(
      'Preparando StOmni',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: textColor,
        fontSize: 26,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.5,
      ),
    );

    return Material(
      color: bgColor,
      child: SafeArea(
        child: Semantics(
          liveRegion: true,
          label:
              'Preparando StOmni. Sincronizando inventario y configurando tu espacio de trabajo.',
          child: Stack(
            children: [
              Center(
                child: AnimatedBuilder(
                  animation: _glowAnimation,
                  child: Container(
                    width: 250,
                    height: 250,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(
                            alpha: isDark ? 0.08 : 0.05,
                          ),
                          blurRadius: 80,
                          spreadRadius: 30,
                        ),
                      ],
                    ),
                  ),
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _glowAnimation.value,
                      child: child,
                    );
                  },
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _iconScaleAnimation,
                            child: Container(
                              padding: const EdgeInsets.all(28),
                              decoration: BoxDecoration(
                                color: primary.withValues(
                                  alpha: isDark ? 0.15 : 0.1,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.storefront_outlined,
                                size: 80,
                                color: primary,
                              ),
                            ),
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _iconScaleAnimation.value,
                                child: child,
                              );
                            },
                          ),
                          const SizedBox(height: 45),
                          if (reduceMotion)
                            title
                          else
                            Shimmer.fromColors(
                              baseColor: textColor,
                              highlightColor: primary.withValues(alpha: 0.6),
                              period: const Duration(milliseconds: 2500),
                              child: title,
                            ),
                          const SizedBox(height: 12),
                          Text(
                            'Sincronizando inventario y configurando\ntu espacio de trabajo...',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 15,
                              height: 1.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 45),
                          Container(
                            height: 4,
                            width: 180,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: primary.withValues(alpha: 0.15),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                backgroundColor: Colors.transparent,
                                color: primary,
                                minHeight: 4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Un momento, estamos dejando todo listo.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: secondaryText.withValues(alpha: 0.7),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
