// Real two-session lock races. Synthetic fixtures; loopback database only.
import fs from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {loadLocalSupabaseConfig} from './saas_backup_common.mjs';
const {dbUrl}=loadLocalSupabaseConfig({requireServiceRole:false});
const u=new URL(dbUrl);
if(!['localhost','127.0.0.1','[::1]'].includes(u.hostname)) throw Error('Local database required');
const args=['--dbname',dbUrl,'-X','-q','-A','-t','-v','ON_ERROR_STOP=1'];
function sql(query) {
 const r=spawnSync('psql',args,{input:query,encoding:'utf8',timeout:20000});
 if(r.status!==0) throw Error(r.stderr||'psql failed');
 return r.stdout.trim();
}
const contract=fs.readFileSync('supabase/tests/database/financial_2c6b_atomic_credit_note_contract_test.sql','utf8');
const fixture=contract.split('-- BEGIN ASSERTIONS')[0];
const bajaFixture=contract.slice(contract.indexOf('CREATE TEMP TABLE _baja'),contract.indexOf('SELECT public.tributario_finalizar_proceso'));
const fixtures=[]; const evidence=[];
function prepare(index,baja=false) {
 let q=fixture.replaceAll('-840030001',String(-850000001-index*2)).replaceAll('-840030002',String(-850000002-index*2));
 q+=`SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org_a FROM _fin2c2_f))::text,true);`;
 if(baja) q+=`SELECT public.nota_credito_finalizar((SELECT nc_ok FROM _refund_fixture),NULL,'aceptado','{}');`+bajaFixture;
 q+=`SELECT to_jsonb(f)||to_jsonb(x)${baja?"||jsonb_build_object('baja_id',(SELECT id FROM _baja))":''} FROM _fin2c2_f f CROSS JOIN _refund_fixture x; COMMIT;`;
 const lines=sql(q).split('\n');const f=JSON.parse(lines.findLast(l=>l.startsWith('{')&&l.includes('org_a')));
 fixtures.push(f);return f;
}
function context(f,other=false) {return `SET LOCAL statement_timeout='12s'; SET LOCAL lock_timeout='10s'; SET LOCAL request.jwt.claim.sub='${other?f.actor_other:f.actor_admin}'; SET LOCAL request.headers='{"x-stomni-organization-id":"${other?f.org_b:f.org_a}"}';`;}
const nc=(id)=>`SELECT public.nota_credito_finalizar('${id}',NULL,'aceptado','{}');`;
const baja=(f)=>`SELECT public.tributario_finalizar_proceso('${f.baja_id}',NULL,'aceptado','{}');`;
const payment=(f)=>`SELECT private.financial_2c2_record_transfer_payment('${f.org_a}',${f.sale_a},'${randomUUID()}','PEN',20,now());`;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function session(label,input,keep=false) {
 const p=spawn('psql',args,{stdio:['pipe','pipe','pipe']});let out='',err='';
 p.stdout.on('data',x=>out+=x);p.stderr.on('data',x=>err+=x);
 const done=new Promise(resolve=>p.on('close',code=>resolve({code,out,err})));
 p.stdin.write(`SET application_name='${label}';\n`+input+'\n');if(!keep)p.stdin.end();
 return {p,done,get output(){return out;}};
}
async function waitFor(check,label){for(let i=0;i<100;i++){if(check())return;await delay(50);}throw Error('Timed out: '+label);}
async function race(name,f,first,second,{reject=false,other=false}={}) {
 const tag='nc2c6b_'+randomUUID().replaceAll('-','');
 const a=session(tag+'a','BEGIN;'+context(f)+first+"SELECT 'READY';",true);let b;
 try {
  await waitFor(()=>a.output.includes('READY'),name+' leader');
  b=session(tag+'b','BEGIN;'+context(f,other)+second+'COMMIT;');
  if(other){const r=await b.done;if(r.code!==0)throw Error(r.err);}
  else {
   await waitFor(()=>sql(`SELECT count(*) FROM pg_stat_activity WHERE application_name='${tag}b' AND wait_event_type='Lock';`)==='1',name+' blocked follower');
  }
  a.p.stdin.end('COMMIT;\n');const ar=await a.done;const br=await b.done;
  if(ar.code!==0||((br.code===0)===reject))throw Error(name+': '+ar.err+' '+br.err);
  if(reject && !/saldo|excede|exceder|monto|pendiente/i.test(br.err))throw Error('Unexpected rejection: '+br.err);
  const audit=JSON.parse(sql(`SELECT to_jsonb(a) FROM private.financial_2c_audit_sale('${f.org_a}',${f.sale_a}) a;`));
  if(!audit.apta_para_motor)throw Error(name+' failed audit');
  const due=Number(sql(`SELECT sum(saldo_pendiente) FROM private.financial_2c4_installments('${f.org_a}',${f.sale_a},NULL);`));
  if(due!==Number(audit.saldo_calculado))throw Error('Quota mismatch');
  evidence.push({name,blocked_follower:!other,follower_rejected:reject,exigible:Number(audit.exigible_eventos),cobros:Number(audit.cobros_eventos),saldo:due});
 } finally {a.p.stdin.end();a.p.kill();if(b)b.p.kill();}
}
function expectLast(e,c){const r=evidence.at(-1);if(r.exigible!==e||r.cobros!==c)throw Error('Unexpected race outcome '+JSON.stringify(r));}
try {
 let f=prepare(0);await race('NC before payment',f,nc(f.nc_ok),payment(f),{reject:true});expectLast(30,40);
 f=prepare(1);await race('payment before NC',f,payment(f),nc(f.nc_ok));expectLast(30,60);
 f=prepare(2);await race('duplicate acceptance',f,nc(f.nc_ok),nc(f.nc_ok));expectLast(30,40);
 f=prepare(3,true);await race('baja before payment',f,baja(f),payment(f));expectLast(100,60);
 f=prepare(4,true);await race('baja before another NC',f,baja(f),nc(f.nc_pending));expectLast(85,40);
 f=prepare(5,true);await race('another NC before baja',f,nc(f.nc_pending),baja(f));expectLast(85,40);
 f=prepare(6,true);await race('duplicate baja',f,baja(f),baja(f));expectLast(100,40);
 f=prepare(7);await race('different tenants independent',f,nc(f.nc_ok),nc(f.req),{other:true});expectLast(30,40);
 console.log('2C6B: 8 real two-session races passed');
} finally {
 // Delete only synthetic tenant IDs created by this invocation. Never remote.
 for(const f of fixtures) sql(`BEGIN; SET LOCAL session_replication_role=replica;
 DO $cleanup$ DECLARE r record; BEGIN FOR r IN SELECT DISTINCT c.table_schema,c.table_name FROM information_schema.columns c JOIN information_schema.tables t USING(table_schema,table_name) WHERE c.column_name='organization_id' AND c.table_schema IN ('public','private') AND t.table_type='BASE TABLE' LOOP
 EXECUTE format('DELETE FROM %I.%I WHERE organization_id=ANY($1)',r.table_schema,r.table_name) USING ARRAY['${f.org_a}'::uuid,'${f.org_b}'::uuid]; END LOOP; END $cleanup$;
 DELETE FROM auth.users WHERE id IN ('${f.actor_admin}','${f.actor_operator}','${f.actor_other}'); DELETE FROM public.organizations WHERE id IN ('${f.org_a}','${f.org_b}'); COMMIT;`);
 fs.mkdirSync('.dart_tool/saas',{recursive:true});
 fs.writeFileSync('.dart_tool/saas/financial-2c6b-concurrency.json',JSON.stringify({passed:evidence.length===8,scenarios:evidence},null,2)+'\n');
}
