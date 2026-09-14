class OrganizationSubscription {
  const OrganizationSubscription({
    required this.organizationId,
    required this.planId,
    required this.planCode,
    required this.planName,
    required this.status,
    required this.assignmentReason,
    required this.cancelAtPeriodEnd,
    required this.revision,
    this.currentPeriodStart,
    this.currentPeriodEnd,
  });

  final String organizationId;
  final String planId;
  final String planCode;
  final String planName;
  final String status;
  final String assignmentReason;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final bool cancelAtPeriodEnd;
  final int revision;

  bool get isUsable => status == 'active' || status == 'trialing';

  factory OrganizationSubscription.fromJson(Map<String,dynamic> json) {
    final organizationId=json['organization_id']?.toString()??'';
    final planId=json['plan_id']?.toString()??'';
    final planCode=json['plan_code']?.toString()??'';
    final planName=json['plan_name']?.toString()??'';
    final status=json['status']?.toString()??'';
    final assignmentReason=json['assignment_reason']?.toString()??'';
    final revision=(json['revision'] as num?)?.toInt();
    if(organizationId.isEmpty||planId.isEmpty||planCode.isEmpty||planName.isEmpty||status.isEmpty||revision==null){
      throw const FormatException('La suscripción de la organización es inválida.');
    }
    DateTime? parseDate(Object? raw)=>raw==null?null:DateTime.tryParse(raw.toString());
    return OrganizationSubscription(
      organizationId:organizationId,
      planId:planId,
      planCode:planCode,
      planName:planName,
      status:status,
      assignmentReason:assignmentReason,
      currentPeriodStart:parseDate(json['current_period_start']),
      currentPeriodEnd:parseDate(json['current_period_end']),
      cancelAtPeriodEnd:json['cancel_at_period_end']==true,
      revision:revision,
    );
  }
}
