import 'organization_subscription.dart';

class BillingSummary {
  const BillingSummary({
    required this.subscription,
    required this.providerAccountBound,
    this.billingProvider,
  });

  final OrganizationSubscription subscription;
  final String? billingProvider;
  final bool providerAccountBound;

  factory BillingSummary.fromJson(Map<String, dynamic> json) {
    return BillingSummary(
      subscription: OrganizationSubscription.fromJson(json),
      billingProvider: json['billing_provider']?.toString(),
      providerAccountBound: json['provider_account_bound'] == true,
    );
  }
}
