import '../domain/organization_signup.dart';
import 'organization_signup_gateway.dart';

class OrganizationSignupUseCase {
  const OrganizationSignupUseCase(this.gateway);

  final OrganizationSignupGateway gateway;

  Future<OrganizationSignupState> getState() => gateway.getState();

  Future<OrganizationSignupResult> create(OrganizationSignupRequest request) {
    final displayName = request.displayName.trim();
    final countryCode = request.countryCode.trim().toUpperCase();
    final currencyCode = request.currencyCode.trim().toUpperCase();
    final timezone = request.timezone.trim();
    final legalName = request.legalName?.trim();

    if (displayName.isEmpty || displayName.length > 160) {
      throw const FormatException('El nombre comercial es obligatorio y debe tener hasta 160 caracteres.');
    }
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(countryCode)) {
      throw const FormatException('El país debe usar un código ISO de 2 letras.');
    }
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode)) {
      throw const FormatException('La moneda debe usar un código ISO de 3 letras.');
    }
    if (timezone.isEmpty || timezone.length > 80) {
      throw const FormatException('La zona horaria IANA es obligatoria.');
    }
    if (legalName != null && legalName.isNotEmpty && legalName.length > 200) {
      throw const FormatException('La razón social debe tener hasta 200 caracteres.');
    }

    return gateway.createOrganization(
      OrganizationSignupRequest(
        displayName: displayName,
        countryCode: countryCode,
        currencyCode: currencyCode,
        timezone: timezone,
        legalName: legalName == null || legalName.isEmpty ? null : legalName,
      ),
    );
  }
}
