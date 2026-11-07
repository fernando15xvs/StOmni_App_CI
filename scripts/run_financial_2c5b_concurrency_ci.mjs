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
const contract=fs.readFileSync('supabase/tests/database/financial_2c5b_refund_settlement_contract_test.sql','utf8');
const fixture=contract.slice(0,contract.indexOf('SELECT pg_temp.check_rf'));
const ncContract=fs.readFileSync('supabase/tests/database/financial_2c6b_atomic_credit_note_contract_test.sql','utf8');
const bajaFixture=ncContract.slice(ncContract.indexOf('CREATE TEMP TABLE _baja'),ncContract.indexOf('SELECT public.tributario_finalizar_proceso'));
const cashContract=fs.readFileSync('supabase/tests/database/financial_2c5b_cash_refund_contract_test.sql','utf8');
// The shared refund fixture already adds a MAIN branch per tenant. The cash-specific
// branch is a secondary one; otherwise the partial unique MAIN index rejects the race.
const cashFixture=cashContract.slice(cashContract.indexOf('CREATE TEMP TABLE _rf_cash'),cashContract.indexOf('UPDATE _rf SET reservation_id'))
  .replace("c.branch,f.org_a,'RFC','Refund test',true,'active'",
           "c.branch,f.org_a,'RFC','Refund test',false,'active'");
const fixtures=[]; const evidence=[];
function prepare(index,{held=false,cash=false,two=false}={}) {
 let q=fixture.replaceAll('-840030001',String(-860000001-index*2)).replaceAll('-840030002',String(-860000002-index*2));
 q+=bajaFixture;
 q+=`SELECT pg_temp.cmd('bank_reconcile',jsonb_build_object('bank_id',bank_id,'balance',20,'effective_at',clock_timestamp(),'evidence_ref','race-bank-opening','evidence_sha256',repeat('a',64))) FROM _rf;`;
 if(cash) q+=cashFixture+`SET LOCAL session_replication_role=replica; UPDATE public.sesiones_caja SET monto_apertura=50 WHERE id=(SELECT sess FROM _rf_cash); SET LOCAL session_replication_role=origin;`;
 if(held)q+=`UPDATE _rf SET reservation_id=(pg_temp.cmd('reserve',jsonb_build_object('case_id',case_id,'amount',8))->>'reservation_id')::uuid;`;
 if(two)q+=`SELECT public.nota_credito_finalizar((SELECT nc_pending FROM _refund_fixture),NULL,'aceptado','{}');
 CREATE TEMP TABLE _second(id uuid);
 INSERT INTO _second SELECT (private.financial_2c5b_open_refund_case(f.org_a,f.sale_a,x.nc_pending,gen_random_uuid(),15,'Concurrent second refund')->>'caso_id')::uuid FROM _fin2c2_f f CROSS JOIN _refund_fixture x;
 UPDATE _second SET id=(pg_temp.cmd('reserve',jsonb_build_object('case_id',id,'amount',15))->>'reservation_id')::uuid;`;
 q+=`SELECT to_jsonb(f)||to_jsonb(x)||to_jsonb(r)||jsonb_build_object('baja_id',(SELECT id FROM _baja))${cash?"||jsonb_build_object('session_id',(SELECT sess FROM _rf_cash))":''}${two?"||jsonb_build_object('second_id',(SELECT id FROM _second))":''} FROM _fin2c2_f f CROSS JOIN _refund_fixture x CROSS JOIN _rf r; COMMIT;`;
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
 const tag='refund2c5b_'+randomUUID().replaceAll('-','');
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
  if(reject && !/reserved|reservation|surplus|Refund|Payout|cash session|eligible|limit/i.test(br.err))throw Error('Unexpected rejection: '+br.err);
  const audit=JSON.parse(sql(`SELECT to_jsonb(a) FROM private.financial_2c_audit_sale('${f.org_a}',${f.sale_a}) a;`));
  if(!audit.apta_para_motor)throw Error(name+' failed audit');
  const due=Number(sql(`SELECT sum(saldo_pendiente) FROM private.financial_2c4_installments('${f.org_a}',${f.sale_a},NULL);`));
  if(due!==Number(audit.saldo_calculado))throw Error('Quota mismatch');
  evidence.push({name,blocked_follower:!other,follower_rejected:reject,exigible:Number(audit.exigible_eventos),cobros:Number(audit.cobros_eventos),saldo:due});
 } finally {a.p.stdin.end();a.p.kill();if(b)b.p.kill();}
}
function expectLast(e,c){const r=evidence.at(-1);if(r.exigible!==e||r.cobros!==c)throw Error('Unexpected race outcome '+JSON.stringify(r));}
const command=(f,action,payload,request=randomUUID())=>`SELECT private.financial_refund_command('${f.org_a}','${request}','${action}','${JSON.stringify(payload).replaceAll("'","''")}'::jsonb);`;
const reserve=f=>command(f,'reserve',{case_id:f.case_id,amount:8});
const release=f=>command(f,'release',{reservation_id:f.reservation_id});
const payout=(f,id=f.reservation_id)=>command(f,'settle',{reservation_id:id,...(f.session_id?{cash_session_id:f.session_id}:{bank_id:f.bank_id}),effective_at:new Date().toISOString(),evidence_ref:'race-payout-'+randomUUID(),evidence_sha256:'b'.repeat(64)});
const close=f=>`UPDATE public.sesiones_caja SET estado='CERRADA',fecha_cierre=clock_timestamp() WHERE organization_id='${f.org_a}' AND id='${f.session_id}';`;
try {
 let f=prepare(0);await race('competing reservations',f,reserve(f),reserve(f),{reject:true});expectLast(30,40);
 f=prepare(1,{held:true});let pay=payout(f);await race('duplicate payout',f,pay,pay);expectLast(30,32);
 f=prepare(2,{held:true});await race('payout before release',f,payout(f),release(f),{reject:true});expectLast(30,32);
 f=prepare(3,{held:true});await race('release before payout',f,release(f),payout(f),{reject:true});expectLast(30,40);
 f=prepare(4);await race('reserve before baja',f,reserve(f),baja(f),{reject:true});expectLast(30,40);
 f=prepare(5);await race('baja before reserve',f,baja(f),reserve(f),{reject:true});expectLast(100,40);
 f=prepare(6,{held:true,two:true});await race('bank funds cannot be spent twice',f,payout(f),payout(f,f.second_id),{reject:true});expectLast(15,32);
 if(Number(sql(`SELECT balance FROM private.refund_bank_accounts WHERE organization_id='${f.org_a}' AND id='${f.bank_id}';`))!==12)throw Error('Incorrect bank balance');
 f=prepare(7,{held:true,cash:true});await race('cash payout before closure',f,payout(f),close(f));expectLast(30,32);
 f=prepare(8,{held:true,cash:true});await race('cash closure before payout',f,close(f),payout(f),{reject:true});expectLast(30,40);
 console.log('2C5B-B: 9 real two-session races passed');
} finally {
 // Delete only synthetic tenant IDs created by this invocation. Never remote.
 for(const f of fixtures) sql(`BEGIN; SET LOCAL session_replication_role=replica;
 DO $cleanup$ DECLARE r record; BEGIN FOR r IN SELECT DISTINCT c.table_schema,c.table_name FROM information_schema.columns c JOIN information_schema.tables t USING(table_schema,table_name) WHERE c.column_name='organization_id' AND c.table_schema IN ('public','private') AND t.table_type='BASE TABLE' LOOP
 EXECUTE format('DELETE FROM %I.%I WHERE organization_id=ANY($1)',r.table_schema,r.table_name) USING ARRAY['${f.org_a}'::uuid,'${f.org_b}'::uuid]; END LOOP; END $cleanup$;
 DELETE FROM auth.users WHERE id IN ('${f.actor_admin}','${f.actor_operator}','${f.actor_other}'); DELETE FROM public.organizations WHERE id IN ('${f.org_a}','${f.org_b}'); COMMIT;`);
 fs.mkdirSync('.dart_tool/saas',{recursive:true});
 fs.writeFileSync('.dart_tool/saas/financial-2c5b-concurrency.json',JSON.stringify({passed:evidence.length===9,scenarios:evidence},null,2)+'\n');
}
