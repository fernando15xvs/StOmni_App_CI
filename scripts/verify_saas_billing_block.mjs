import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const gates=[
 'scripts/verify_saas_subscription_plans.mjs',
 'scripts/verify_saas_organization_subscriptions.mjs',
 'scripts/verify_saas_plan_entitlements.mjs',
 'scripts/verify_saas_subscription_enforcement.mjs',
 'scripts/verify_saas_billing_provider_interface.mjs',
];
const errors=[];
for(const gate of gates){
 const result=spawnSync(process.execPath,[path.join(root,gate)],{cwd:root,encoding:'utf8',env:process.env});
 if(result.status!==0){errors.push(`${gate} falló`);const output=`${result.stdout??''}\n${result.stderr??''}`.trim();if(output)errors.push(output);}
}
if(errors.length){console.error('SaaS billing block gate FAILED:');errors.forEach(e=>console.error(`  - ${e}`));process.exit(1);}
console.log(`SaaS billing block gate OK (${gates.length} fases estáticas).`);
console.log('Validación dinámica comercial continúa pendiente en T02/T03/T07/T09/T10/T14/T17.');
