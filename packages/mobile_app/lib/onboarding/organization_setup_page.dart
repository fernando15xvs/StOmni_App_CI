import 'package:core_logic/core_logic.dart';
import 'package:core_logic/onboarding/domain/organization_signup.dart';
import 'package:core_logic/onboarding/providers/organization_signup_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class OrganizationSetupPage extends ConsumerStatefulWidget {
  const OrganizationSetupPage({
    super.key,
    required this.onOrganizationCreated,
  });

  final VoidCallback onOrganizationCreated;

  @override
  ConsumerState<OrganizationSetupPage> createState() =>
      _OrganizationSetupPageState();
}

class _OrganizationSetupPageState extends ConsumerState<OrganizationSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _displayName = TextEditingController();
  final _legalName = TextEditingController();
  final _country = TextEditingController();
  final _currency = TextEditingController();
  final _timezone = TextEditingController();

  bool _submitting = false;
  bool _organizationCreated = false;
  String? _error;

  @override
  void dispose() {
    _displayName.dispose();
    _legalName.dispose();
    _country.dispose();
    _currency.dispose();
    _timezone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_organizationCreated && !_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (!_organizationCreated) {
        await ref
            .read(organizationSignupUseCaseProvider)
            .create(
              OrganizationSignupRequest(
                displayName: _displayName.text,
                legalName: _legalName.text,
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
      widget.onOrganizationCreated();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is FormatException
            ? error.message.toString()
            : ErrorMapper.map(error);
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? 48 : 24,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(wide ? 40 : 24),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.apartment_rounded,
                              size: 48,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'Crea tu empresa en StOmni',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Estos datos crean tu espacio empresarial. El '
                              'identificador, el plan inicial y los permisos '
                              'se asignan de forma segura en el servidor.',
                              style: theme.textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 28),
                            if (wide)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: _businessFields()),
                                  const SizedBox(width: 24),
                                  Expanded(child: _regionalFields()),
                                ],
                              )
                            else ...[
                              _businessFields(),
                              const SizedBox(height: 16),
                              _regionalFields(),
                            ],
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
                                onPressed: _submitting ? null : _submit,
                                icon: _submitting
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
            );
          },
        ),
      ),
    );
  }

  Widget _businessFields() => Column(
    children: [
      TextFormField(
        controller: _displayName,
        enabled: !_organizationCreated,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Nombre comercial',
          hintText: 'Ej. Mi Empresa',
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? 'Ingresa el nombre comercial.'
            : null,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _legalName,
        enabled: !_organizationCreated,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Razón social (opcional)',
        ),
      ),
    ],
  );

  Widget _regionalFields() => Column(
    children: [
      TextFormField(
        controller: _country,
        enabled: !_organizationCreated,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'País (ISO 2 letras)',
          hintText: 'Ej. PE',
        ),
        validator: (value) =>
            RegExp(r'^[A-Za-z]{2}$').hasMatch(value?.trim() ?? '')
            ? null
            : 'Usa un código de 2 letras.',
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _currency,
        enabled: !_organizationCreated,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Moneda (ISO 3 letras)',
          hintText: 'Ej. PEN',
        ),
        validator: (value) =>
            RegExp(r'^[A-Za-z]{3}$').hasMatch(value?.trim() ?? '')
            ? null
            : 'Usa un código de 3 letras.',
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _timezone,
        enabled: !_organizationCreated,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'Zona horaria IANA',
          hintText: 'Ej. America/Lima',
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? 'Ingresa la zona horaria.'
            : null,
      ),
    ],
  );
}
