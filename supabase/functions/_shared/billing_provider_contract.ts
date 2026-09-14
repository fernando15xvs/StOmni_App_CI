export type CanonicalSubscriptionStatus =
  | 'trialing'
  | 'active'
  | 'past_due'
  | 'suspended'
  | 'canceled';

export interface NormalizedBillingSubscriptionEvent {
  providerCode: string;
  eventId: string;
  eventType: string;
  payloadSha256: string;
  externalSubscriptionRef: string;
  externalPriceRef: string;
  status: CanonicalSubscriptionStatus;
  periodStart?: string | null;
  periodEnd?: string | null;
  cancelAtPeriodEnd: boolean;
}

/**
 * Un adaptador concreto debe verificar firma/autenticidad ANTES de devolver
 * el evento normalizado. StOmni no permite que el body recibido controle
 * organization_id ni plan_code; esos valores se resuelven server-side.
 */
export interface BillingProviderAdapter {
  readonly providerCode: string;
  verifyAndNormalize(request: Request): Promise<NormalizedBillingSubscriptionEvent>;
}

export function validateNormalizedBillingEvent(
  event: NormalizedBillingSubscriptionEvent,
): NormalizedBillingSubscriptionEvent {
  if (!/^[a-z][a-z0-9_-]{1,31}$/.test(event.providerCode)) {
    throw new Error('Invalid billing provider code');
  }
  if (!event.eventId.trim() || event.eventId.length > 200) {
    throw new Error('Invalid billing event id');
  }
  if (!event.eventType.trim() || event.eventType.length > 120) {
    throw new Error('Invalid billing event type');
  }
  if (!/^[0-9a-f]{64}$/.test(event.payloadSha256)) {
    throw new Error('Invalid billing payload digest');
  }
  if (!event.externalSubscriptionRef.trim() || event.externalSubscriptionRef.length > 200) {
    throw new Error('Invalid external subscription reference');
  }
  if (!event.externalPriceRef.trim() || event.externalPriceRef.length > 200) {
    throw new Error('Invalid external price reference');
  }
  return event;
}
