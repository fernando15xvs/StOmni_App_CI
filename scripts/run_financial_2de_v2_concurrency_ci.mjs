// 2D-E: real two-session concurrency against certified v2, loopback PostgreSQL only.
// Financial fixtures use a synthetic v5 ticket and internal bank reversal; no
// SUNAT issuance, external banking integration or remote database connections.
import fs from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {loadLocalSupabaseConfig} from './saas_backup_common.mjs';
const {dbUrl}=loadLocalSupabaseConfig({requireServiceRole:false});
const u=new URL(dbUrl);
if(!['localhost','127.0.0.1','[::1]'].includes(u.hostname))
  throw Error('Refusing to run financial races outside loopback PostgreSQL');
const args=['--dbname',dbUrl,'-X','-q','-A','-t','-v','ON_ERROR_STOP=1'];
const timeout=25000;
function sql(query){
  const r=spawnSync('psql',args,{input:query,encoding:'utf8',timeout});
  if(r.status!==0) throw Error(r.stderr||r.error?.message||'psql failed');
  return r.stdout.trim();
}
const test=fs.readFileSync('supabase/tests/database/financial_2dd_certified_v2_nc_contract_test.sql','utf8');
const cut=test.indexOf('SELECT ok(');
if(cut<0)throw Error('2D-D fixture marker missing');
const fixture=test.slice(0,cut);
if(!fixture.includes('BEGIN;')||!fixture.includes('UPDATE _2dc_results r SET reversed='))
  throw Error('2D-D E2E fixture changed: refuse unsafe concurrency fixture');
const created=[];const evidence=[];
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function prepare(index,{accepted=false}={}){
 const base=840140000+index*100;
 let query=fixture;
 for(const suffix of [101,102,103,104,105])
   query=query.replaceAll(String(840130000+suffix),String(base+suffix-100));
 // Fixture includes an accepted NC without matching financial transition.
 // Change to pending under replica solely for the synthetic fixture, then
 // exercise public.nota_credito_finalizar with all guards enabled in races.
 query+=`SET LOCAL session_replication_role=replica;
 UPDATE public.notas_credito SET estado='pendiente_envio',aceptado_at=NULL
 WHERE id=(SELECT id FROM _2dd_nc);
 SET LOCAL session_replication_role=origin;`;
 if(accepted)query+=`SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2db_fixture),true);
 SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _2db_fixture))::text,true);
 SELECT public.nota_credito_finalizar((SELECT id FROM _2dd_nc),NULL,'aceptado','{}'::jsonb);`;
 query+=`SELECT jsonb_build_object('org',f.org,'actor',f.actor,
  'sale',(f.result20->>'venta_id')::bigint,'nc',n.id,
  'schedule',(r.reversed->>'schedule_id')::uuid,
  'old_schedule',(r.reversed->>'previous_schedule_id')::uuid)
 FROM _2db_fixture f CROSS JOIN _2dc_results r CROSS JOIN _2dd_nc n;
 COMMIT;`;
 const lines=sql(query).split('\n');
 const row=lines.findLast(x=>x.startsWith('{')&&x.includes('"org"'));
 if(!row)throw Error('No fixture identity in psql output');
 const f=JSON.parse(row);created.push(f);return f;
}
function context(f){return `SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='12s';
SET LOCAL request.jwt.claim.sub='${f.actor}';
SET LOCAL request.headers='{"x-stomni-organization-id":"${f.org}"}';`;}
function session(name,query,keep=false){
 const p=spawn('psql',args,{stdio:['pipe','pipe','pipe']});
 let out='',err='';p.stdout.on('data',d=>out+=d);
 p.stderr.on('data',d=>err+=d);
 const done=new Promise(resolve=>p.on('close',code=>resolve({code,out,err})));
 p.stdin.write(`SET application_name='${name}';\n${query}\n`);
 if(!keep)p.stdin.end();
 return {p,done,get output(){return out;}};
}
async function waitFor(fn,reason){
 for(let i=0;i<130;i++){if(fn())return;await delay(70)}
 throw Error('Timed out '+reason);
}
const nc=f=>`SELECT public.nota_credito_finalizar('${f.nc}',NULL,'aceptado','{}');`;
const payment=(f,amount)=>`SELECT private.financial_2c2_record_transfer_payment('${f.org}',${f.sale},'${randomUUID()}','PEN',${amount},clock_timestamp());`;
const baja=f=>`INSERT INTO private.financial_nc_intents(organization_id,venta_id,nota_credito_id,tx_id)
 VALUES('${f.org}',${f.sale},'${f.nc}',pg_catalog.pg_current_xact_id());
 UPDATE public.notas_credito SET estado_baja_tributaria='aceptada',
 baja_aceptada_at=clock_timestamp() WHERE organization_id='${f.org}' AND id='${f.nc}';
 DELETE FROM private.financial_nc_intents
 WHERE organization_id='${f.org}' AND venta_id=${f.sale}
  AND nota_credito_id='${f.nc}' AND tx_id=pg_catalog.pg_current_xact_id();`;
async function race(name,f,leader,follower,{reject=false,expectedE,expectedC,expectedNC}){
 const tag='credit2de_'+randomUUID().replaceAll('-','');
 const a=session(tag+'a','BEGIN;'+context(f)+leader+"SELECT 'READY';",true);
 let b=null;
 try {
  await waitFor(()=>a.output.includes('READY'),name+' leader transaction');
  b=session(tag+'b','BEGIN;'+context(f)+follower+'COMMIT;');
  await waitFor(()=>sql(`SELECT count(*) FROM pg_stat_activity WHERE application_name='${tag}b' AND wait_event_type='Lock';`)==='1',name+' second session blocked on live lock');
  a.p.stdin.end('COMMIT;\n');
  const ar=await a.done,br=await b.done;
  if(ar.code!==0)throw Error(name+' leader failed: '+ar.err);
  if(reject ? br.code===0 : br.code!==0)throw Error(name+' unexpected follower: '+br.err);
  if(reject&&!/saldo|excede|exceder|monto|insuficient|balance|importe|cuota|limite/i.test(br.err))
    throw Error(name+' unexpected rejection reason: '+br.err);
  const audit=JSON.parse(sql(`SELECT to_jsonb(a) FROM private.financial_2c_audit_sale('${f.org}',${f.sale}) a;`));
  if(!audit.apta_para_motor)throw Error(name+' audit failure '+JSON.stringify(audit));
  const row=JSON.parse(sql(`SELECT jsonb_build_object(
     'active_count',(SELECT count(*) FROM public.venta_cronogramas WHERE organization_id='${f.org}' AND venta_id=${f.sale} AND estado='vigente'),
     'v2',(SELECT version FROM public.venta_cronogramas WHERE id='${f.schedule}'),
     'v1',(SELECT estado FROM public.venta_cronogramas WHERE id='${f.old_schedule}'),
     'v1_total',(SELECT sum(importe_vigente) FROM public.venta_cuotas WHERE cronograma_id='${f.old_schedule}'),
     'due',(SELECT sum(saldo_pendiente) FROM private.financial_2c4_installments('${f.org}',${f.sale},NULL)),
     'note_events',(SELECT count(*) FROM public.venta_eventos_financieros WHERE organization_id='${f.org}' AND venta_id=${f.sale} AND nota_credito_id='${f.nc}' AND tipo='nota_credito')
   );`));
  if(Number(audit.exigible_eventos)!==expectedE||Number(audit.cobros_eventos)!==expectedC
    ||Number(audit.saldo_calculado)!==Number(row.due)||row.active_count!==1
    ||row.v2!==2||row.v1!=='sustituido'||Number(row.v1_total)!==80
    ||row.note_events!==expectedNC)throw Error(name+' post-commit mismatch: '+JSON.stringify({audit,row}));
  evidence.push({name,blocked_follower:true,rejected:reject,exigible:expectedE,cobros:expectedC,
   saldo:Number(row.due),note_events:row.note_events});
 }finally{a.p.stdin.end();a.p.kill();if(b)b.p.kill()}
}
try{
 let f=prepare(0);await race('v2 NC before payment20',f,nc(f),payment(f,20),{expectedE:70,expectedC:20,expectedNC:1});
 f=prepare(1);await race('v2 payment20 before NC',f,payment(f,20),nc(f),{expectedE:70,expectedC:20,expectedNC:1});
 f=prepare(2);await race('v2 NC before excessive payment80',f,nc(f),payment(f,80),{reject:true,expectedE:70,expectedC:0,expectedNC:1});
 f=prepare(3);await race('v2 payment80 before NC surplus',f,payment(f,80),nc(f),{expectedE:70,expectedC:80,expectedNC:1});
 f=prepare(4);await race('v2 duplicate NC acceptance',f,nc(f),nc(f),{expectedE:70,expectedC:0,expectedNC:1});
 f=prepare(5,{accepted:true});await race('v2 baja before payment80',f,baja(f),payment(f,80),{expectedE:100,expectedC:80,expectedNC:1});
 f=prepare(6,{accepted:true});await race('v2 payment60 before baja',f,payment(f,60),baja(f),{expectedE:100,expectedC:60,expectedNC:1});
 console.log('2D-E: '+evidence.length+' real two-session certified-v2 finance races passed');
}finally{
 // All persisted records belong to random synthetic tenants in loopback DB.
 for(const f of created){
  sql(`BEGIN; SET LOCAL session_replication_role=replica;
 DO $cleanup$ DECLARE r record; BEGIN
 FOR r IN SELECT DISTINCT c.table_schema,c.table_name
 FROM information_schema.columns c JOIN information_schema.tables t USING(table_schema,table_name)
 WHERE c.column_name='organization_id' AND c.table_schema IN ('public','private')
   AND t.table_type='BASE TABLE'
 LOOP EXECUTE format('DELETE FROM %I.%I WHERE organization_id=ANY($1)',r.table_schema,r.table_name)
 USING ARRAY['${f.org}'::uuid]; END LOOP; END $cleanup$;
 DELETE FROM auth.users WHERE id='${f.actor}';
 DELETE FROM public.organizations WHERE id='${f.org}'; COMMIT;`);
 }
 fs.mkdirSync('.dart_tool/saas',{recursive:true});
 fs.writeFileSync('.dart_tool/saas/financial-2de-v2-concurrency.json',
   JSON.stringify({passed:evidence.length===7,scenarios:evidence},null,2)+'\n');
}
