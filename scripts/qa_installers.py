"""Build QA installers on CI; publish only to the private source repository."""
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

SOURCE = 'fernando15xvs/StOmni_App'
MIRROR = 'fernando15xvs/StOmni_App_CI'
BRANCH = 'feature/saas-multitenant-foundation'
QA_URL = 'https://iqooedpkihmzkmynsisl.supabase.co'
VERSION = '2.0.1'
FEED_BRANCH = 'qa-update-feed'
ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist/qa'
ANDROID = ROOT / 'packages/mobile_app/android'
MANIFEST = ROOT / 'docs/saas/CI_CANDIDATE_SOURCE.json'
SECRET_NAMES = (
    'STOMNI_QA_PUBLISHABLE_KEY', 'STOMNI_ANDROID_KEYSTORE_BASE64',
    'STOMNI_ANDROID_STORE_PASSWORD', 'STOMNI_ANDROID_KEY_PASSWORD',
    'STOMNI_ANDROID_KEY_ALIAS', 'STOMNI_SOURCE_RELEASE_TOKEN',
)
CI_ONLY = {
    'docs/saas/CI_CANDIDATE_SOURCE.json', '.github/saas-ci-trigger',
    '.github/saas-installers-trigger', '.github/include-probe-trigger',
    '.github/mount-probe-trigger', '.github/pgcrypto-probe-trigger',
    '.github/workflows/supabase_include_probe.yml',
    '.github/workflows/supabase_mount_probe.yml',
    '.github/workflows/supabase_pgcrypto_probe.yml',
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def context(env=os.environ, manifest=None):
    require(env.get('GITHUB_REPOSITORY') == MIRROR, 'Run only in CI mirror')
    require(env.get('GITHUB_REF') == 'refs/heads/' + BRANCH, 'Wrong branch')
    require(env.get('GITHUB_EVENT_NAME') in ('push', 'workflow_dispatch'),
            'Untrusted event')
    m = manifest if manifest is not None else json.loads(MANIFEST.read_text(encoding='utf-8-sig'))
    require(m.get('source_repository') == SOURCE and m.get('source_branch') == BRANCH,
            'Wrong source provenance')
    require(re.fullmatch(r'[0-9a-f]{40}', m.get('source_sha', '')), 'Invalid source SHA')
    require(re.fullmatch(r'[0-9a-f]{40}', env.get('GITHUB_SHA', '')), 'Invalid CI SHA')
    number = 10000 + int(env['GITHUB_RUN_NUMBER'])
    require(10000 < number < 65536, 'Build number outside Windows version range')
    return m, number


def run(*args, cwd=ROOT, capture=False):
    command = shutil.which(str(args[0])) or str(args[0])
    result = subprocess.run([command, *map(str, args[1:])], cwd=cwd,
                            check=True, capture_output=capture, text=True)
    return result.stdout if capture else None


def api(path, payload=None, method=None, data=None, content_type='application/json'):
    host = 'https://uploads.github.com' if path.startswith('/upload/') else 'https://api.github.com'
    if path.startswith('/upload/'):
        path = path[len('/upload'):]
    body = json.dumps(payload).encode() if payload is not None else data
    headers = {
        'Authorization': 'Bearer ' + os.environ['STOMNI_SOURCE_RELEASE_TOKEN'],
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': content_type,
    }
    req = urllib.request.Request(host + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=300) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Do not echo response bodies or request headers that may contain secrets.
        raise RuntimeError(f'GitHub API failed: HTTP {error.code}') from None


def check_source_tree(source, mirror):
    require(source and mirror, 'Empty source or mirror tree')
    require(all(mirror.get(path) == sha for path, sha in source.items()),
            'Mirror differs from source snapshot')
    require(set(mirror) - set(source) <= CI_ONLY, 'Unapproved mirror-only files')


def provenance(m):
    repo = api('/repos/' + SOURCE)
    require(repo.get('private') is True, 'Installer destination must remain private')
    tree = api(f'/repos/{SOURCE}/git/trees/{m["source_sha"]}?recursive=1')
    require(not tree.get('truncated'), 'Source tree response truncated')
    source = {x['path']: (x['mode'], x['sha']) for x in tree['tree'] if x['type'] == 'blob'}
    mirror = {}
    for entry in run('git', 'ls-tree', '-r', 'HEAD', capture=True).splitlines():
        metadata, path = entry.split('\t', 1)
        mode, kind, sha = metadata.split()
        require(kind == 'blob', 'Submodules not supported')
        mirror[path] = (mode, sha)
    check_source_tree(source, mirror)


def preflight():
    m, _ = context()
    for name in SECRET_NAMES:
        require(bool(os.environ.get(name)), f'Missing repository secret: {name}')
    require(os.environ['STOMNI_QA_PUBLISHABLE_KEY'].startswith('sb_publishable_'),
            'Use a QA publishable key, never a privileged key')
    provenance(m)
    print('QA configuration and source snapshot verified; secret values not printed.')


def build():
    _, number = context()
    DIST.mkdir(parents=True, exist_ok=True)
    key = os.environ['STOMNI_QA_PUBLISHABLE_KEY']
    require(key.startswith('sb_publishable_'), 'Expected QA publishable key')
    jks = ANDROID / 'app/stomni-qa.jks'
    properties = ANDROID / 'key.properties'
    try:
        jks.write_bytes(base64.b64decode(os.environ['STOMNI_ANDROID_KEYSTORE_BASE64'], validate=True))
        values = {
            'storePassword': os.environ['STOMNI_ANDROID_STORE_PASSWORD'],
            'keyPassword': os.environ['STOMNI_ANDROID_KEY_PASSWORD'],
            'keyAlias': os.environ['STOMNI_ANDROID_KEY_ALIAS'],
            'storeFile': 'stomni-qa.jks',
        }
        # Provision passwords as hex to avoid Java properties escaping ambiguities.
        require(all(re.fullmatch(r'[A-Za-z0-9_-]+', v) for k, v in values.items() if k != 'storeFile'),
                'Signing values must use letters, digits, underscore or hyphen')
        properties.write_text(''.join(f'{k}={v}\n' for k, v in values.items()), encoding='utf-8')
        flags = ['--release', '--no-pub', f'--build-name={VERSION}', f'--build-number={number}',
                 f'--dart-define=SUPABASE_URL={QA_URL}', f'--dart-define=SUPABASE_ANON_KEY={key}']
        run('flutter', 'build', 'apk', *flags, cwd=ROOT / 'packages/mobile_app')
        apk = DIST / f'StOmni-SaaS-QA-{VERSION}-{number}-android.apk'
        shutil.copyfile(ROOT / 'packages/mobile_app/build/app/outputs/flutter-apk/app-release.apk', apk)
        sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
        signers = sorted(sdk.glob('build-tools/*/apksigner.bat'),
                         key=lambda p: tuple(int(x) for x in re.findall(r'\d+', p.parent.name)))
        require(bool(signers), 'Android apksigner missing')
        cert = run(signers[-1], 'verify', '--verbose', '--print-certs', apk, capture=True)
        require('Android Debug' not in cert, 'Debug certificate forbidden for QA release')
        (DIST / 'android-signing-info.txt').write_text(cert, encoding='utf-8')
        run('flutter', 'config', '--enable-windows-desktop')
        run('flutter', 'build', 'windows', *flags, cwd=ROOT / 'packages/desktop_app')
    finally:
        properties.unlink(missing_ok=True)
        jks.unlink(missing_ok=True)


def package():
    _, number = context()
    compiler = Path(os.environ['ProgramFiles(x86)']) / 'Inno Setup 6/ISCC.exe'
    require(compiler.is_file(), 'Inno Setup 6 missing on Windows runner')
    bundle = ROOT / 'packages/desktop_app/build/windows/x64/runner/Release'
    require((bundle / 'StOmni.exe').is_file(), 'Windows executable missing')
    # Flutter requires the MSVC runtime; bundle the redistributable DLLs app-locally.
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    vs = run(vswhere, '-latest', '-products', '*', '-property', 'installationPath', capture=True).strip()
    runtimes = sorted(Path(vs).glob('VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT'))
    require(bool(runtimes), 'MSVC redistributable runtime not found')
    for dll in runtimes[-1].glob('*.dll'):
        shutil.copy2(dll, bundle / dll.name)
    run(compiler, f'/DAppVersion={VERSION}', f'/DBuildNumber={number}',
        f'/DBundleDir={bundle}', f'/DOutputPath={DIST}', ROOT / 'packaging/windows/stomni-qa.iss')
    setup = DIST / f'StOmni-SaaS-QA-{VERSION}-{number}-windows-x64-setup.exe'
    require(setup.is_file(), 'Windows installer missing')
    # Exercise install, upgrade-in-place, contents and uninstall on the disposable runner.
    with tempfile.TemporaryDirectory(prefix='stomni-install-test-') as tmp:
        install = Path(tmp) / 'app'
        for _ in range(2):
            run(setup, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', f'/DIR={install}')
            for path in ('StOmni.exe', 'flutter_windows.dll', 'data/icudtl.dat'):
                require((install / path).is_file(), f'Installed file missing: {path}')
        run(install / 'unins000.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        require(not (install / 'StOmni.exe').exists(), 'Uninstall did not remove executable')
    binaries = sorted([*DIST.glob('*.apk'), *DIST.glob('*.exe')])
    require(len(binaries) == 2, 'Expected exactly Android and Windows installers')
    checksums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in binaries)
    (DIST / 'SHA256SUMS.txt').write_text(checksums, encoding='utf-8')



def release_feed(number, tag):
    """Public version metadata only; never expose private credentials or binaries."""
    require(re.fullmatch(r'saas-qa-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-attempt-[1-9][0-9]*', tag),
            'Invalid QA tag')
    return {
        'schema': 1, 'product': 'stomni-saas-qa',
        'version': VERSION, 'build_number': number, 'release_tag': tag,
        'assets': {
            'android': f'StOmni-SaaS-QA-{VERSION}-{number}-android.apk',
            'windows': f'StOmni-SaaS-QA-{VERSION}-{number}-windows-x64-setup.exe',
        },
    }


def ci_api(path, payload=None, method=None, allow_missing=False):
    """Use CI's own short-lived workflow token, never the private source PAT."""
    token = os.environ['STOMNI_CI_FEED_TOKEN']
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request('https://api.github.com' + path, data=body,
        headers={'Authorization': 'Bearer ' + token,
                 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28',
                 'Content-Type': 'application/json'}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404:
            return None
        raise RuntimeError(f'CI update feed API failed: HTTP {error.code}') from None


def publish_feed(number, tag):
    """Metadata-only CI branch, separate from the sanitized source snapshot."""
    require(os.environ['GITHUB_REPOSITORY'] == MIRROR, 'Update feed only from CI')
    metadata = release_feed(number, tag)
    # Create a dedicated branch if absent. GitHub Actions on the SaaS branch
    # remain the only compilation entrypoint; this branch contains NO assets.
    ref = ci_api(f'/repos/{MIRROR}/git/ref/heads/{FEED_BRANCH}', allow_missing=True)
    if ref is None:
        ci_api(f'/repos/{MIRROR}/git/refs',
               {'ref': 'refs/heads/' + FEED_BRANCH, 'sha': os.environ['GITHUB_SHA']},
               method='POST')
    old = ci_api(f'/repos/{MIRROR}/contents/latest.json?ref={FEED_BRANCH}',
                 allow_missing=True)
    message = f'ci(updates): publish QA metadata {VERSION} build {number}'
    body = {
        'branch': FEED_BRANCH, 'message': message,
        'content': base64.b64encode((json.dumps(metadata, sort_keys=True) + '\n').encode()).decode(),
    }
    if old is not None:
        body['sha'] = old['sha']
        # Never downgrade the public feed on a late rerun of an older build.
        previous = json.loads(base64.b64decode(old['content']).decode())
        require(int(previous.get('build_number', 0)) <= number, 'Refuse feed rollback')
    ci_api(f'/repos/{MIRROR}/contents/latest.json', body, method='PUT')


def publish():
    m, number = context()
    provenance(m)
    files = sorted(DIST.iterdir())
    expected = {f'StOmni-SaaS-QA-{VERSION}-{number}-android.apk',
                f'StOmni-SaaS-QA-{VERSION}-{number}-windows-x64-setup.exe',
                'SHA256SUMS.txt', 'android-signing-info.txt'}
    require({p.name for p in files} == expected and all(p.stat().st_size for p in files),
            'Incomplete installer set')
    tag = f'saas-qa-{VERSION}-{number}-attempt-{os.environ["GITHUB_RUN_ATTEMPT"]}'
    body = (f'Versión de desarrollo para Supabase StOmniApp ({QA_URL}).\n\n'
            f'SOURCE: {m["source_sha"]}\nCI: {os.environ["GITHUB_SHA"]}\n'
            f'Validación y compilación: https://github.com/{MIRROR}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n\n'
            'Android: APK universal firmado con clave QA estable.\n'
            'Windows: instalador x64, sin certificado Authenticode comercial.\n'
            'Windows puede mostrar editor desconocido. Instala y actualiza StOmni SaaS QA.\n'
            'No es una versión de producción ni sustituye la aceptación manual L00–L08.\n')
    release = api(f'/repos/{SOURCE}/releases', payload={
        'tag_name': tag, 'target_commitish': m['source_sha'],
        'name': f'StOmni SaaS QA {VERSION} · build {number}',
        'body': body, 'draft': True, 'prerelease': True, 'make_latest': 'false',
    })
    # Remain a private draft if any upload or checksum verification fails.
    for path in files:
        uploaded = api(f'/upload/repos/{SOURCE}/releases/{release["id"]}/assets?name={path.name}',
                       data=path.read_bytes(), content_type='application/octet-stream')
        require(uploaded.get('size') == path.stat().st_size, 'Uploaded size mismatch')
        require(uploaded.get('digest') == 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(),
                'GitHub asset digest missing or mismatched')
    published = api(f'/repos/{SOURCE}/releases/{release["id"]}',
                    payload={'draft': False, 'prerelease': True, 'make_latest': 'false'}, method='PATCH')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as summary:
        summary.write(f'Installers published only in [private source Releases]({published["html_url"]}).\n')
    publish_feed(number, tag)
    print(published['html_url'])


if __name__ == '__main__':
    try:
        {'preflight': preflight, 'build': build, 'package': package, 'publish': publish}[sys.argv[1]]()
    except (RuntimeError, ValueError, KeyError) as error:
        print(f'::error::{error}', file=sys.stderr)
        sys.exit(1)
