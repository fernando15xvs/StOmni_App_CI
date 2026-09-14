import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppVersionText extends StatefulWidget {
  const AppVersionText({
    super.key,
    this.style,
  });

  final TextStyle? style;

  @override
  State<AppVersionText> createState() => _AppVersionTextState();
}

class _AppVersionTextState extends State<AppVersionText> {
  String? _label;

  @override
  void initState() {
    super.initState();
    _cargarVersion();
  }

  Future<void> _cargarVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;

      final version = info.version.trim();
      final buildNumber = info.buildNumber.trim();
      final buildSuffix = buildNumber.isEmpty ? '' : '+$buildNumber';

      setState(() {
        _label = version.isEmpty ? null : 'Versión $version$buildSuffix';
      });
    } catch (e) {
      debugPrint('No se pudo obtener la versión del build: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    if (label == null) {
      return const SizedBox(height: 14);
    }

    return Text(label, style: widget.style);
  }
}
