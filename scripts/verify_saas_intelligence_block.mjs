import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const gates=[
  'scripts/verify_saas_enterprise_audit.mjs',
  'scripts/verify_saas_operational_alerts.mjs',
  'scripts/verify_saas_configurable_dashboard.mjs',
  'scripts/verify_saas_business_assistant.mjs',
];

const errors=[];
for(const gate of gates){
  for(const args of [[],['--self-test']]){
    const result=spawnSync(process.execPath,[path.join(root,gate),...args],{
      cwd:root,encoding:'utf8',env:process.env,
    });
    if(result.status!==0){
      errors.push(`${gate}${args.length?' --self-test':''} falló`);
      const output=`${result.stdout??''}\n${result.stderr??''}`.trim();
      if(output)errors.push(output);
    }
  }
}
if(errors.length){
  console.error('SaaS intelligence block gate FAILED:');
  errors.forEach(error=>console.error(`  - ${error}`));
  process.exit(1);
}
console.log(`SaaS intelligence block gate OK (${gates.length} fases, gate + self-test).`);
