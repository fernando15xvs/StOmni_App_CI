import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String source;

  setUpAll(() {
    source = repositoryFile(
      'scripts/fase5_local_rebuild_verify.ps1',
    ).readAsStringSync();
  });

  test('reconstruccion Fase 5 apunta exclusivamente a Supabase local', () {
    expect(source, contains("'db', 'reset', '--local'"));
    expect(source, contains("'test', 'db', '--local'"));
    expect(source, contains("'db', 'lint', '--local'"));
    expect(source, isNot(contains("'--linked'")));
    expect(source, isNot(contains("'--db-url'")));
  });

  test('bloquea reset mientras el baseline oficial siga vacio', () {
    expect(source, contains("20260722180810_remote_schema.sql"));
    expect(source, contains(r'$baselineSize -lt 1024'));
    expect(source, contains('P0 bloqueado'));
  });

  test('valida primero el corte equivalente a produccion', () {
    expect(source, contains("TargetVersion = '20260821191000'"));
    expect(source, contains('fase5_production_fingerprint_test.sql'));
    expect(
      source,
      contains(
        "'db', 'reset', '--local', '--no-seed', '--version', \$TargetVersion",
      ),
    );
  });

  test('despues reconstruye Fase 5 completa y ejecuta contratos DB', () {
    expect(source, contains('debt_payment_v2_contract_test.sql'));
    expect(source, contains('warehouse_deactivation_contract_test.sql'));
    expect(source, contains('business_config_rpc_contract_test.sql'));
    expect(source, contains('expense_mutation_atomicity_contract_test.sql'));
    expect(source, contains('data_api_surface_hardening_contract_test.sql'));
    expect(source, contains('tributary_rpc_legacy_cleanup_contract_test.sql'));
    expect(
      source,
      contains("@('test', 'db', '--local') + \$fase5ContractTests"),
    );
    expect(source, contains("'db', 'reset', '--local', '--no-seed'"));
  });
}
