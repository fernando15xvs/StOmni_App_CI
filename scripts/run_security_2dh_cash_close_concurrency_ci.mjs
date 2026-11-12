// 2D-H: two-session race between customer debt cash payment and closing cash.
// Local loopback PostgreSQL only. Never connects to remote Supabase or SUNAT.
import fs from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {loadLocalSupabaseConfig} from './saas_backup_common.mjs';

const {dbUrl}=loadLocalSupabaseConfig({requireServiceRole:false});
const hostname=new URL(dbUrl).hostname;
if (!['localhost','127.0.0.1','[::1]'].includes(hostname)) {
  throw Error('Refusing cash-close concurrency test outside loopback PostgreSQL');
}
const args=['--dbname',dbUrl,'-X','-q','-A','-t','-v','ON_ERROR_STOP=1'];
function sql(query) {
  const result=spawnSync('psql',args,{input:query,encoding:'utf8',timeout:25000});
  if (result.status!==0) throw Error(result.stderr||result.error?.message||'psql failed');
  return result.stdout.trim();
}
const contract=fs.readFileSync(
  'supabase/tests/database/financial_2c3b_atomic_cash_writer_contract_test.sql','utf8'
);
const end=contract.indexOf('CREATE TEMP TABLE _c3b_check');
if (!contract.startsWith('-- 2C3B:')||end<1000) throw Error('2C3B fixture changed');
const fixture=contract.slice(0,end);
const created=[];
const evidence=[];
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));

function prepare(index) {
  const saleA=-870040001-index*2,saleB=-870040002-index*2;
  let body=fixture.replaceAll('-840040001',String(saleA))
    .replaceAll('-840040002',String(saleB));
  body+=[
    'GRANT ALL ON _c3 TO authenticated;',
    'SET LOCAL session_replication_role=replica;',
    "UPDATE public.app_users SET base_role='admin' WHERE user_id=(SELECT actor_a FROM _c3);",
    "UPDATE public.empleados SET rol='admin' WHERE auth_id=(SELECT actor_a FROM _c3);",
    "UPDATE public.roles SET code='admin' WHERE id=(SELECT role_a FROM _c3);",
    'SET LOCAL session_replication_role=origin;',
    "SELECT jsonb_build_object('org_a',(SELECT org_a FROM _c3),'org_b',(SELECT org_b FROM _c3),",
    " 'actor_a',(SELECT actor_a FROM _c3),'actor_b',(SELECT actor_b FROM _c3),",
    " 'sale_a',(SELECT sale_a FROM _c3),'sess_a',(SELECT sess_a FROM _c3),",
    " 'fecha_pago',(SELECT fecha_pago FROM _c3));",
    'COMMIT;'
  ].join('\n')+'\n';
  const lines=sql(body).split('\n');
  const line=lines.findLast(x=>x.startsWith('{')&&x.includes('"org_a"'));
  if (!line) throw Error('Synthetic committed fixture ID was not returned');
  const value=JSON.parse(line);
  created.push(value);
  return value;
}
function context(f) {
  return [
    "SET LOCAL statement_timeout='15s';",
    "SET LOCAL lock_timeout='12s';",
    "SET LOCAL request.jwt.claim.sub='"+f.actor_a+"';",
    "SET LOCAL request.headers='{\"x-stomni-organization-id\":\""+f.org_a+"\"}';"
  ].join('\n')+'\n';
}
function payment(f,request,amount=20) {
  return "SET LOCAL ROLE authenticated;\n"+
    "SELECT public.procesar_pago_deuda_v2('"+request+"',true,"+
      f.sale_a+","+amount+",'efectivo','"+f.fecha_pago+"'::timestamptz,false);\n"+
    "RESET ROLE;\n";
}
function closure(f) {
  return "UPDATE public.sesiones_caja SET estado='CERRADA',fecha_cierre=clock_timestamp()"+
    " WHERE organization_id='"+f.org_a+"' AND id='"+f.sess_a+"';\n";
}
function session(label,input,keep=false) {
  const proc=spawn('psql',args,{stdio:['pipe','pipe','pipe']});
  let output='',error='';
  proc.stdout.on('data',d=>output+=d);
  proc.stderr.on('data',d=>error+=d);
  const done=new Promise(resolve=>proc.on('close',code=>resolve({code,output,error})));
  proc.stdin.write("SET application_name='"+label+"';\n"+input+'\n');
  if (!keep)proc.stdin.end();
  return {proc,done,get output(){return output;}};
}
async function waitFor(check,label) {
  for (let i=0;i<140;i++) {
    if (check()) return;
    await delay(60);
  }
  throw Error('No verified lock wait: '+label);
}
function audit(f) {
  const query=[
    'SELECT jsonb_build_object(',
    " 'status',(SELECT estado FROM public.sesiones_caja WHERE organization_id='"+f.org_a+"' AND id='"+f.sess_a+"'),",
    " 'balance',(SELECT saldo_pendiente FROM public.venta_cuentas_financieras WHERE organization_id='"+f.org_a+"' AND venta_id="+f.sale_a+"),",
    " 'cash_count',(SELECT count(*) FROM public.pagos_venta WHERE organization_id='"+f.org_a+"' AND venta_id="+f.sale_a+" AND cash_session_id='"+f.sess_a+"'),",
    " 'operations',(SELECT count(*) FROM public.venta_operaciones_financieras WHERE organization_id='"+f.org_a+"' AND venta_id="+f.sale_a+" AND tipo='cobro' AND resultado='aplicado'),",
    " 'valid',(SELECT apta_para_motor FROM private.financial_2c_audit_sale('"+f.org_a+"',"+f.sale_a+"))",
    ');'
  ].join('\n');
  return JSON.parse(sql(query));
}
async function race(name,f,leader,follower,{reject,balance,cashCount,status}) {
  const tag='dhcash_'+randomUUID().replaceAll('-','');
  const a=session(tag+'a','BEGIN;\n'+context(f)+leader+"SELECT 'READY';\n",true);
  let b;
  try {
    await waitFor(()=>a.output.includes('READY'),name+' leader');
    b=session(tag+'b','BEGIN;\n'+context(f)+follower+'COMMIT;\n');
    await waitFor(()=>sql("SELECT COUNT(*) FROM pg_stat_activity WHERE application_name='"+tag+"b' AND wait_event_type='Lock';")==='1',
      name+' blocked second connection');
    a.proc.stdin.end('COMMIT;\n');
    const [ar,br]=await Promise.all([a.done,b.done]);
    if(ar.code!==0) throw Error(name+' leader failed: '+ar.error);
    if((br.code!==0)!==reject) throw Error(name+' unexpected follower: '+br.error);
    if(reject && !/closed|cash|sesion|sesión|saldo|exceed|importe|balance|open|caja/i.test(br.error))
      throw Error(name+' unexpected SQL rejection: '+br.error);
    const state=audit(f);
    if(state.valid!==true||Number(state.balance)!==balance||
       Number(state.cash_count)!==cashCount||state.status!==status)
      throw Error(name+' financial/cash ledger invariant failed: '+JSON.stringify(state));
    evidence.push({name,blocked_follower:true,rejected:reject,balance:Number(state.balance),
      cash_payments:Number(state.cash_count),canonical_payments:Number(state.operations),
      status:state.status});
  } finally {
    try{a.proc.stdin.end();}catch{}
    a.proc.kill();
    if(b)b.proc.kill();
  }
}
try {
  let f=prepare(0);
  await race('closure commits before debt cash collection',f,closure(f),payment(f,randomUUID()),
    {reject:true,balance:100,cashCount:0,status:'CERRADA'});
  f=prepare(1);
  await race('debt cash collection commits before closure',f,payment(f,randomUUID()),closure(f),
    {reject:false,balance:80,cashCount:1,status:'CERRADA'});
  f=prepare(2);
  const sameRequest=randomUUID();
  await race('parallel replay of same cash request UUID',f,payment(f,sameRequest),payment(f,sameRequest),
    {reject:false,balance:80,cashCount:1,status:'ABIERTA'});
  f=prepare(3);
  await race('competing cash amounts cannot overpay',f,payment(f,randomUUID(),80),payment(f,randomUUID(),40),
    {reject:true,balance:20,cashCount:1,status:'ABIERTA'});
  if (evidence.length!==4)throw Error('Incomplete four-scenario concurrency test');
  console.log('2D-H: four genuine two-session debt/cash-close races passed');
} finally {
  for (const f of created) {
    const cleanup=[
      'BEGIN;',
      'SET LOCAL session_replication_role=replica;',
      'DO $cleanup$ DECLARE r record; BEGIN',
      'FOR r IN SELECT DISTINCT c.table_schema,c.table_name',
      'FROM information_schema.columns c JOIN information_schema.tables t USING(table_schema,table_name)',
      "WHERE c.column_name='organization_id' AND c.table_schema IN ('public','private')",
      " AND t.table_type='BASE TABLE'",
      "LOOP EXECUTE format('DELETE FROM %I.%I WHERE organization_id=ANY($1)',r.table_schema,r.table_name)",
      "USING ARRAY['"+f.org_a+"'::uuid,'"+f.org_b+"'::uuid]; END LOOP; END $cleanup$;",
      "DELETE FROM auth.users WHERE id IN ('"+f.actor_a+"','"+f.actor_b+"');",
      "DELETE FROM public.organizations WHERE id IN ('"+f.org_a+"','"+f.org_b+"');",
      'COMMIT;'
    ].join('\n');
    sql(cleanup);
  }
  fs.mkdirSync('.dart_tool/saas',{recursive:true});
  fs.writeFileSync('.dart_tool/saas/security-2dh-cash-close-concurrency.json',
    JSON.stringify({passed:evidence.length===4,scenarios:evidence},null,2)+'\n');
}
