import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import 'package:core_logic/platform/image_selection.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import 'business_capabilities_page.dart';

class ConfiguracionNegocioPage extends ConsumerStatefulWidget {
  const ConfiguracionNegocioPage({super.key});

  @override
  ConsumerState<ConfiguracionNegocioPage> createState() =>
      _ConfiguracionNegocioPageState();
}

class _ConfiguracionNegocioPageState
    extends ConsumerState<ConfiguracionNegocioPage> {
  final _formKey = GlobalKey<FormState>();

  bool _cargando = true;
  bool _guardando = false;
  String? _errorCarga;

  final _razonSocialCtrl = TextEditingController();
  final _nombreComercialCtrl = TextEditingController();
  final _rucCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();

  // Datos fiscales necesarios para APIsPERU/SUNAT.
  final _ubigeoCtrl = TextEditingController();
  final _departamentoCtrl = TextEditingController();
  final _provinciaCtrl = TextEditingController();
  final _distritoCtrl = TextEditingController();

  // El teléfono es opcional.
  final _telefonoCtrl = TextEditingController();

  Uint8List? _logoNuevoBytes;
  String _logoNuevoExtension = 'png';
  String _logoUrlExistente = '';
  String _codLocal = '0000';

  @override
  void initState() {
    super.initState();
    _cargarDatosActuales();
  }

  @override
  void dispose() {
    _razonSocialCtrl.dispose();
    _nombreComercialCtrl.dispose();
    _rucCtrl.dispose();
    _direccionCtrl.dispose();
    _ubigeoCtrl.dispose();
    _departamentoCtrl.dispose();
    _provinciaCtrl.dispose();
    _distritoCtrl.dispose();
    _telefonoCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarDatosActuales() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      if (ConfiguracionService.fiscalProfile == null) {
        final cargado = await ConfiguracionService.cargarNegocio();
        if (!cargado && ConfiguracionService.fiscalProfile == null) {
          throw const UserFacingException(
            'No se pudo cargar la configuración de la empresa. Inténtalo nuevamente.',
          );
        }
      }

      final profile = ConfiguracionService.fiscalProfile;
      if (profile == null) {
        throw const UserFacingException(
          'No se encontró la configuración de la empresa.',
        );
      }

      _razonSocialCtrl.text = profile.legalName;
      _nombreComercialCtrl.text = profile.tradeName;
      _rucCtrl.text = profile.taxIdentifier;
      _direccionCtrl.text = profile.address.street;

      _ubigeoCtrl.text = profile.address.geoCode;
      _departamentoCtrl.text = profile.address.region;
      _provinciaCtrl.text = profile.address.province;
      _distritoCtrl.text = profile.address.district;

      _telefonoCtrl.text = profile.phone;
      _codLocal = profile.locationCode.trim().isEmpty
          ? '0000'
          : profile.locationCode.trim();

      final urlDb = profile.logoUrl;
      _logoUrlExistente =
          BusinessBranding.parseLogoUri(urlDb)?.toString() ?? '';

      if (mounted) {
        setState(() => _errorCarga = null);
      }
    } catch (e, st) {
      debugPrint('ConfiguracionNegocioPage: fallo al cargar configuración: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        setState(() => _errorCarga = ErrorMapper.map(e));
      }
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _seleccionarLogo() async {
    try {
      final image = await ImageSelectionService.select(
        const ImageSelectionRequest(
          source: ImageSelectionSource.gallery,
          maxWidth: 400,
          maxHeight: 400,
          imageQuality: 80,
        ),
      );
      if (image == null || !mounted) return;

      setState(() {
        _logoNuevoBytes = image.bytes;
        _logoNuevoExtension = image.extension;
      });
    } catch (e, st) {
      debugPrint('ConfiguracionNegocioPage: fallo al seleccionar logo: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        _mostrarError(ErrorMapper.map(e));
      }
    }
  }

  void _eliminarLogo() {
    setState(() {
      _logoNuevoBytes = null;
      _logoNuevoExtension = 'png';
      _logoUrlExistente = '';
    });
  }

  Future<void> _guardarCambios() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _guardando = true);

    String? logoSubidoEnEsteIntento;
    var configuracionConfirmada = false;

    try {
      String urlFinal = _logoUrlExistente;

      if (_logoNuevoBytes != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Subiendo logo...'),
            duration: Duration(seconds: 2),
          ),
        );

        final urlPublica = await ConfiguracionService.subirLogo(
          _logoNuevoBytes!,
          _logoNuevoExtension,
        );

        if (urlPublica == null || urlPublica.trim().isEmpty) {
          throw const UserFacingException(
            'No se pudo subir el logo. Revisa tu conexión e inténtalo nuevamente.',
          );
        }
        logoSubidoEnEsteIntento = urlPublica;
        urlFinal = urlPublica;
      }

      final currentProfile = ConfiguracionService.fiscalProfile;
      if (currentProfile == null) {
        throw const UserFacingException(
          'No se encontró el perfil fiscal activo. Vuelve a cargar la configuración.',
        );
      }

      final razonSocial = _razonSocialCtrl.text.trim();
      final nombreComercial = _nombreComercialCtrl.text.trim();
      final updatedProfile = currentProfile.copyWith(
        locationCode: _codLocal,
        taxIdentifier: _rucCtrl.text.trim(),
        legalName: razonSocial,
        tradeName: nombreComercial.isEmpty ? razonSocial : nombreComercial,
        address: currentProfile.address.copyWith(
          street: _direccionCtrl.text.trim(),
          locationCode: _codLocal,
          geoCode: _ubigeoCtrl.text.trim(),
          region: _departamentoCtrl.text.trim().toUpperCase(),
          province: _provinciaCtrl.text.trim().toUpperCase(),
          district: _distritoCtrl.text.trim().toUpperCase(),
        ),
        phone: _telefonoCtrl.text.trim(),
        logoUrl: urlFinal,
      );

      final exito = await ConfiguracionService.actualizarPerfilFiscal(
        updatedProfile,
      );

      if (!exito) {
        if (logoSubidoEnEsteIntento != null) {
          await ConfiguracionService.eliminarLogoPropioPorUrl(
            logoSubidoEnEsteIntento,
          );
          logoSubidoEnEsteIntento = null;
        }
        if (mounted) {
          _mostrarError(
            'No se pudo guardar la configuración. Inténtalo nuevamente.',
          );
        }
        return;
      }

      configuracionConfirmada = true;

      // Fuerza una recarga para que documentos y facturación usen el perfil
      // confirmado por backend, no los valores temporales del formulario.
      await ConfiguracionService.cargarNegocio();

      if (!mounted) return;
      ref.invalidate(businessBrandingProvider(false));
      _mostrarExito('¡Datos de la empresa guardados correctamente!');
      Navigator.pop(context);
    } catch (e, st) {
      debugPrint(
        'ConfiguracionNegocioPage: fallo al guardar configuración: $e',
      );
      debugPrintStack(stackTrace: st);

      // Si el write lógico no fue confirmado, la imagen recién subida no debe
      // quedar huérfana. El adaptador fiscal limpia el logo anterior solo tras
      // confirmar el nuevo snapshot.
      if (!configuracionConfirmada && logoSubidoEnEsteIntento != null) {
        await ConfiguracionService.eliminarLogoPropioPorUrl(
          logoSubidoEnEsteIntento,
        );
      }

      if (mounted) {
        _mostrarError(ErrorMapper.map(e));
      }
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  String? _validarRuc(String? value) {
    final ruc = value?.trim() ?? '';

    if (ruc.isEmpty) return 'El RUC es obligatorio';
    if (!RegExp(r'^\d{11}$').hasMatch(ruc)) {
      return 'El RUC debe contener exactamente 11 dígitos';
    }

    return null;
  }

  String? _validarUbigeo(String? value) {
    final ubigeo = value?.trim() ?? '';
    if (ubigeo.isEmpty) return 'El ubigeo es obligatorio';
    if (!RegExp(r'^\d{6}$').hasMatch(ubigeo)) {
      return 'El ubigeo debe contener exactamente 6 dígitos';
    }

    return null;
  }

  String? _validarTextoObligatorio(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Este campo es obligatorio';
    }
    return null;
  }

  void _mostrarError(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  void _mostrarExito(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.empresa),
    );
  }

  InputDecoration _decoracionInput(
    String label,
    IconData icon, {
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
      prefixIcon: Icon(icon, color: Colors.grey),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade700
              : Colors.grey.shade300,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade700
              : Colors.grey.shade300,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.empresa, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.red, width: 2),
      ),
      floatingLabelStyle: TextStyle(
        color: AppColors.empresa,
        fontWeight: FontWeight.bold,
      ),
      filled: true,
      fillColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E1E1E)
          : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  Widget _buildImageSection() {
    final tieneImagen = _logoNuevoBytes != null || _logoUrlExistente.isNotEmpty;

    return Center(
      child: Stack(
        children: [
          GestureDetector(
            onTap: _seleccionarLogo,
            child: Container(
              height: 180,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey.shade300),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: _logoNuevoBytes != null
                    ? Image.memory(_logoNuevoBytes!, fit: BoxFit.contain)
                    : _logoUrlExistente.isNotEmpty
                    ? Image.network(
                        _logoUrlExistente,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: 45,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 50,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Toca para agregar el logo',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'Se utilizará en tickets y comprobantes',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          Positioned(
            bottom: 10,
            right: 10,
            child: CircleAvatar(
              backgroundColor: AppColors.empresa,
              radius: 20,
              child: const Icon(
                Icons.image_search_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          if (tieneImagen)
            Positioned(
              top: 10,
              right: 10,
              child: GestureDetector(
                onTap: _eliminarLogo,
                child: CircleAvatar(
                  backgroundColor: Colors.red.withValues(alpha: 0.9),
                  radius: 15,
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required List<Widget> children,
    String? subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
              ),
            ],
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildGeneralInfo() {
    return _buildSectionCard(
      title: 'Datos del Negocio',
      children: [
        TextFormField(
          controller: _razonSocialCtrl,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput(
            'Razón Social / Nombre legal',
            Icons.business,
          ),
          validator: _validarTextoObligatorio,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _nombreComercialCtrl,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput(
            'Nombre comercial',
            Icons.storefront_outlined,
          ),
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _rucCtrl,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ],
          decoration: _decoracionInput('RUC', Icons.numbers),
          validator: _validarRuc,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _telefonoCtrl,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s]')),
            LengthLimitingTextInputFormatter(20),
          ],
          decoration: _decoracionInput('Teléfono (opcional)', Icons.phone),
        ),
      ],
    );
  }

  Widget _buildFiscalInfo() {
    return _buildSectionCard(
      title: 'Domicilio fiscal',
      subtitle:
          'Estos datos se usarán para construir el comprobante electrónico.',
      children: [
        TextFormField(
          controller: _direccionCtrl,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput('Dirección fiscal', Icons.location_on),
          validator: _validarTextoObligatorio,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _ubigeoCtrl,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: _decoracionInput(
            'Ubigeo',
            Icons.pin_drop_outlined,
            helperText: 'Código de 6 dígitos del distrito',
          ),
          validator: _validarUbigeo,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _departamentoCtrl,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput('Departamento', Icons.map_outlined),
          validator: _validarTextoObligatorio,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _provinciaCtrl,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput(
            'Provincia',
            Icons.location_city_outlined,
          ),
          validator: _validarTextoObligatorio,
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _distritoCtrl,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoracionInput('Distrito', Icons.place_outlined),
          validator: _validarTextoObligatorio,
        ),
      ],
    );
  }

  Widget _buildGuardarButton() {
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        onPressed: _guardando ? null : _guardarCambios,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.empresa,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 4,
        ),
        child: _guardando
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              )
            : const Text(
                'GUARDAR CONFIGURACIÓN',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 54),
            const SizedBox(height: 16),
            Text(
              _errorCarga ?? 'No se pudo cargar la configuración.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _cargarDatosActuales,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text(
            'Configuración de la Empresa',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          backgroundColor: AppColors.empresa,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
          centerTitle: true,
        ),
        body: Center(
          child: CircularProgressIndicator(color: AppColors.empresa),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Configuración de la Empresa',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: AppColors.empresa,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Capacidades del negocio',
            icon: const Icon(Icons.tune),
            onPressed: _guardando
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const BusinessCapabilitiesPage(),
                    ),
                  ),
          ),
        ],
      ),
      body: _errorCarga != null
          ? _buildErrorView()
          : LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: constraints.maxWidth < 600 ? 20 : 32,
                  vertical: 20,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 840),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildImageSection(),
                          const SizedBox(height: 25),
                          _buildGeneralInfo(),
                          const SizedBox(height: 25),
                          _buildFiscalInfo(),
                          const SizedBox(height: 35),
                          _buildGuardarButton(),
                          const SizedBox(height: 55),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
