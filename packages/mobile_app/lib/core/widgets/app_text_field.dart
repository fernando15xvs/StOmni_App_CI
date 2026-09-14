import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_styles.dart';

class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final bool enabled;
  final bool readOnly;
  final bool obscureText;
  final Widget? suffixIcon;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.validator,
    this.enabled = true,
    this.readOnly = false,
    this.obscureText = false,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      enabled: enabled,
      readOnly: readOnly,
      obscureText: obscureText,
      decoration: AppStyles.standardInputDecoration(
        label: label,
        icon: icon,
        hintText: label,
        suffixIcon: suffixIcon,
        fillColor: isDark
            ? Theme.of(context).colorScheme.surface
            : Colors.white,
      ),
    );
  }
}
