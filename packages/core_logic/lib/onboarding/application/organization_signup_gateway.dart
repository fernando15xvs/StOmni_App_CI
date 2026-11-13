import '../domain/organization_signup.dart';

abstract interface class OrganizationSignupGateway {
  Future<OrganizationSignupState> getState();
  Future<List<OrganizationMembership>> listMemberships();
  Future<OrganizationSignupResult> createOrganization(
    OrganizationSignupRequest request,
  );
}
