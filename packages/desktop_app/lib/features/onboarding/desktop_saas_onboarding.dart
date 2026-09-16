import 'package:core_logic/core_logic.dart';
import 'package:core_logic/onboarding/domain/guided_onboarding.dart';
import 'package:core_logic/onboarding/domain/organization_signup.dart';
import 'package:core_logic/onboarding/providers/guided_onboarding_providers.dart';
import 'package:core_logic/onboarding/providers/organization_signup_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopOrganizationSetupView extends ConsumerStatefulWidget {
  const DesktopOrganizationSetupView({super.key, required this.onReady});

  final VoidCallback onReady;

  @override
  ConsumerState<DesktopOrganizationSetupView> createState() =>
      _DesktopOrganizationSetupViewState();
}

class _DesktopOrganizationSetupViewState
    extends ConsumerState<DesktopOrganizationSetupView> {
  final _formKey = GlobalKey<FormState>();
  final _display = TextEditingController();
  final _legal = TextEditingController();
  final _country = TextEditingController();
  final _currency = TextEditingController();
  final _timezone = TextEditingController();

  bool _saving = false;
  bool _organizationCreated = false;
  String? _error;

  @override
  void dispose() {
    _display.dispose();
    _legal.dispose();
    _country.dispose();
    _currency.dispose();
    _timezone.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_saving) return;
    if (!_organizationCreated && !_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_organizationCreated) {
        await ref
            .read(organizationSignupUseCaseProvider)
            .create(
              OrganizationSignupRequest(
                displayName: _display.text,
                legalName: _legal.text,
                countryCode: _country.text,
                currencyCode: _currency.text,
                timezone: _timezone.text,
              ),
            );
        _organizationCreated = true;
      }

      final authorized = await ref
          .read(authControllerProvider.notifier)
          .finishOrganizationSetup();
      if (!authorized) {
        throw StateError(
          'La empresa fue creada, pero todavía no pudimos validar la sesión. '
          'Reintenta para continuar sin volver a crearla.',
        );
      }

      ref.invalidate(organizationSignupStateProvider);
      ref.invalidate(guidedOnboardingProgressProvider);
      widget.onReady();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is FormatException
            ? error.message.toString()
            : ErrorMapper.map(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 4,
            child: Container(
              color: theme.colorScheme.primaryContainer,
              padding: const EdgeInsets.all(56),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.apartment_rounded,
                    size: 68,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 26),
                  Text(
                    'Tu espacio de trabajo',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Crea la empresa que aislará usuarios, inventario, ventas, '
                    'sucursales y configuración dentro de StOmni.',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(44),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Crear empresa',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'El tenant, el rol administrador y el plan inicial '
                          'se asignan en el servidor.',
                        ),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _display,
                          enabled: !_organizationCreated,
                          decoration: const InputDecoration(
                            labelText: 'Nombre comercial',
                          ),
                          validator: _required,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _legal,
                          enabled: !_organizationCreated,
                          decoration: const InputDecoration(
                            labelText: 'Razón social (opcional)',
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _country,
                                enabled: !_organizationCreated,
                                textCapitalization:
                                    TextCapitalization.characters,
                                decoration: const InputDecoration(
                                  labelText: 'País ISO',
                                  hintText: 'PE',
                                ),
                                validator: (value) =>
                                    RegExp(
                                      r'^[A-Za-z]{2}$',
                                    ).hasMatch(value?.trim() ?? '')
                                    ? null
                                    : 'Usa 2 letras.',
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: TextFormField(
                                controller: _currency,
                                enabled: !_organizationCreated,
                                textCapitalization:
                                    TextCapitalization.characters,
                                decoration: const InputDecoration(
                                  labelText: 'Moneda ISO',
                                  hintText: 'PEN',
                                ),
                                validator: (value) =>
                                    RegExp(
                                      r'^[A-Za-z]{3}$',
                                    ).hasMatch(value?.trim() ?? '')
                                    ? null
                                    : 'Usa 3 letras.',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _timezone,
                          enabled: !_organizationCreated,
                          onFieldSubmitted: (_) => _create(),
                          decoration: const InputDecoration(
                            labelText: 'Zona horaria IANA',
                            hintText: 'America/Lima',
                          ),
                          validator: _required,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: _saving ? null : _create,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_forward),
                            label: Text(
                              _organizationCreated
                                  ? 'Revalidar y continuar'
                                  : 'Crear empresa y continuar',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Campo obligatorio.' : null;
}

class DesktopGuidedOnboardingView extends ConsumerStatefulWidget {
  const DesktopGuidedOnboardingView({
    super.key,
    required this.progress,
    required this.onCompleted,
  });

  final GuidedOnboardingProgress progress;
  final VoidCallback onCompleted;

  @override
  ConsumerState<DesktopGuidedOnboardingView> createState() =>
      _DesktopGuidedOnboardingViewState();
}

class _DesktopGuidedOnboardingViewState
    extends ConsumerState<DesktopGuidedOnboardingView> {
  late GuidedOnboardingProgress _progress;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _progress = widget.progress;
  }

  Future<void> _next() async {
    if (_saving || _progress.completed) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(guidedOnboardingUseCaseProvider)
          .completeCurrentStep(_progress);
      if (!mounted) return;
      setState(() => _progress = updated);
      if (updated.completed) {
        ref.invalidate(guidedOnboardingProgressProvider);
        widget.onCompleted();
      }
    } catch (error) {
      if (mounted) setState(() => _error = ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final next = _progress.nextStep;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 300,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Configuración inicial',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 20),
                          for (final step in GuidedOnboardingStep.values)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                _progress.completedSteps.contains(step)
                                    ? Icons.check_circle
                                    : next == step
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                              ),
                              title: Text(_title(step)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(34),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _icon(next),
                            size: 52,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            next == null
                                ? 'Configuración completa'
                                : _title(next),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _description(next),
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 18),
                            Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          const SizedBox(height: 28),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: _saving || next == null ? null : _next,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_forward),
                              label: Text(
                                next == GuidedOnboardingStep.review
                                    ? 'Finalizar'
                                    : 'Confirmar y continuar',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _title(GuidedOnboardingStep step) => switch (step) {
    GuidedOnboardingStep.businessProfile => 'Perfil del negocio',
    GuidedOnboardingStep.modules => 'Módulos y capacidades',
    GuidedOnboardingStep.operations => 'Operación inicial',
    GuidedOnboardingStep.review => 'Revisión final',
  };

  String _description(GuidedOnboardingStep? step) => switch (step) {
    GuidedOnboardingStep.businessProfile =>
      'Confirma que la configuración empresarial creada durante el alta esté '
          'disponible.',
    GuidedOnboardingStep.modules =>
      'Confirma la base de capacidades del tenant. La fuente real permanece '
          'en business_capabilities.',
    GuidedOnboardingStep.operations =>
      'StOmni verificará la sucursal principal y la caja predeterminada de tu '
          'empresa.',
    GuidedOnboardingStep.review =>
      'El backend sólo cierra el proceso si los pasos anteriores están '
          'completos en orden.',
    null => 'La empresa está lista.',
  };

  IconData _icon(GuidedOnboardingStep? step) => switch (step) {
    GuidedOnboardingStep.businessProfile => Icons.storefront_outlined,
    GuidedOnboardingStep.modules => Icons.dashboard_customize_outlined,
    GuidedOnboardingStep.operations => Icons.point_of_sale_outlined,
    GuidedOnboardingStep.review => Icons.fact_check_outlined,
    null => Icons.check_circle_outline,
  };
}
