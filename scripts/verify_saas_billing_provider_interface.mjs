import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  'supabase/migrations/20260908058000_saas_billing_provider_interface.sql',
  'supabase/migrations/20260908058100_saas_billing_edge_rpc_surface.sql',
  'supabase/functions/_shared/billing_provider_contract.ts',
  'packages/core_logic/lib/billing/domain/billing_summary.dart',
  'packages/core_logic/lib/billing/application/billing_summary_gateway.dart',
  'packages/core_logic/lib/billing/data/supabase_billing_summary_gateway.dart',
  'packages/core_logic/lib/billing/providers/billing_summary_providers.dart',
];

const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const source = () => files.map(read).join('\n');
const need = (errors, input, regex, label) => {
  if (!regex.test(input)) errors.push(`Falta: ${label}`);
};

const stripComments = (input) => input
  .replace(/\/\*[\s\S]*?\*\//g, ' ')
  .replace(/^\s*--.*$/gm, ' ')
  .replace(/^\s*\/\/.*$/gm, ' ');

function hasRawWebhookPayload(input) {
  const createBlock = input.match(
    /CREATE TABLE public\.billing_webhook_events\s*\([\s\S]*?\n\);/i,
  )?.[0] ?? '';
  if (/\bpayload\s+(?:json|jsonb|text|bytea)\b/i.test(createBlock)) return true;

  return /ALTER TABLE\s+public\.billing_webhook_events[\s\S]{0,240}?ADD\s+(?:COLUMN\s+)?payload\s+(?:json|jsonb|text|bytea)\b/i.test(input);
}

function verify(input) {
  const errors = [];
  need(errors, input, /CREATE TABLE public\.billing_provider_plan_prices/i, 'mapping provider price -> plan');
  need(errors, input, /PRIMARY KEY\(provider_code,external_price_ref\)/i, 'price ref idempotente');
  need(errors, input, /CREATE TABLE public\.billing_provider_accounts/i, 'binding provider por tenant');
  need(errors, input, /organization_id uuid PRIMARY KEY REFERENCES public\.organizations/i, 'account tenant-owned');
  need(errors, input, /UNIQUE\(provider_code,external_subscription_ref\)/i, 'subscription ref única');
  need(errors, input, /CREATE TABLE public\.billing_webhook_events/i, 'ledger webhook');
  need(errors, input, /PRIMARY KEY\(provider_code,event_id\)/i, 'evento idempotente');
  need(errors, input, /payload_sha256 text NOT NULL/i, 'sólo digest payload');
  need(errors, input, /status text NOT NULL DEFAULT 'received'[\s\S]{0,100}?processed','failed'/i, 'estado evento');
  need(errors, input, /REVOKE ALL ON public\.billing_provider_plan_prices,public\.billing_provider_accounts,public\.billing_webhook_events FROM PUBLIC,anon,authenticated/i, 'tablas billing cerradas');
  need(errors, input, /CREATE OR REPLACE FUNCTION public\.get_my_billing_summary_v1/i, 'resumen saneado cliente');
  need(errors, input, /provider_account_bound/i, 'resumen sin refs externas');
  need(errors, input, /CREATE OR REPLACE FUNCTION private\.set_billing_plan_price_binding_v1/i, 'writer mapping privado');
  need(errors, input, /CREATE OR REPLACE FUNCTION private\.bind_billing_provider_account_v1/i, 'writer account privado');
  need(errors, input, /CREATE OR REPLACE FUNCTION private\.apply_billing_subscription_event_v1/i, 'processor privado');
  need(errors, input, /ON CONFLICT\(provider_code,event_id\) DO NOTHING/i, 'dedupe webhook');
  need(errors, input, /billing_provider_plan_prices bp[\s\S]{0,180}?external_price_ref=p_external_price_ref/i, 'plan se resuelve por mapping');
  need(errors, input, /set_organization_subscription_v1\([\s\S]{0,180}?'billing_sync'/i, 'evento usa writer F7.2');
  need(errors, input, /RETURN jsonb_build_object\('processed',false,'duplicate',true/i, 'duplicate explícito');
  need(errors, input, /status='failed'[\s\S]{0,140}?error_code=v_error/i, 'fallo persistido sin payload');
  need(errors, input, /CREATE OR REPLACE FUNCTION public\.apply_billing_subscription_event_v1/i, 'wrapper Edge service_role');
  need(errors, input, /FROM PUBLIC,anon,authenticated[\s\S]{0,180}?TO service_role/i, 'wrapper cerrado a cliente');
  need(errors, input, /interface BillingProviderAdapter/i, 'contrato provider TS');
  need(errors, input, /verifyAndNormalize\(request: Request\)/i, 'firma verificación proveedor');
  need(errors, input, /organization_id ni plan_code/i, 'contrato no confía org/plan del body');
  need(errors, input, /class BillingSummary/i, 'modelo billing saneado');
  need(errors, input, /['"]get_my_billing_summary_v1['"]/i, 'RPC billing literal Dart');

  if (hasRawWebhookPayload(input)) errors.push('No almacenar payload webhook bruto');
  if (/p_plan_code[\s\S]{0,600}?apply_billing_subscription_event_v1/i.test(input)) {
    errors.push('El webhook no puede aportar plan_code');
  }

  const executable = stripComments(input);
  if (/stripe|mercado_pago|mercadopago|paddle|paypal/i.test(executable)) {
    errors.push('F7.5 debe permanecer agnóstica de proveedor');
  }
  return errors;
}

function selfTest() {
  const valid = source();
  const payloadMutation = `${valid}\nALTER TABLE public.billing_webhook_events ADD COLUMN payload jsonb;`;
  if (payloadMutation === valid || !hasRawWebhookPayload(payloadMutation)) {
    console.error('SaaS billing interface self-test FAILED: fixture payload crudo no construido');
    process.exit(1);
  }

  const noDedupe = valid.replace('ON CONFLICT(provider_code,event_id) DO NOTHING', '');
  if (noDedupe === valid) {
    console.error('SaaS billing interface self-test FAILED: fixture sin dedupe no construido');
    process.exit(1);
  }

  const cases = [
    ['válido', valid, false],
    ['sin dedupe', noDedupe, true],
    ['payload crudo', payloadMutation, true],
    ['provider hardcode', `${valid}\nconst provider='stripe';`, true],
    ['provider sólo comentario', `${valid}\n-- Stripe es un ejemplo, no una dependencia`, false],
  ];

  const failed = [];
  for (const [name, input, shouldFail] of cases) {
    if ((verify(input).length > 0) !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS billing interface self-test FAILED:');
    failed.forEach((name) => console.error(`  - ${name}`));
    process.exit(1);
  }
  console.log(`SaaS billing interface self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(source());
if (errors.length) {
  console.error('SaaS billing interface gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS billing provider interface gate OK (F7.5).');
