import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { nightlyRecipe } from './nightly-release.mjs';

const workflow = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
const helper = fileURLToPath(new URL('./build-products-dir.sh', import.meta.url));

function lookupFor(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert.notEqual(start, -1, `Missing release step: ${name}`);
  const end = workflow.indexOf('\n      - name:', start + 1);
  const block = workflow.slice(start, end < 0 ? undefined : end);
  const assignment = block.split('\n').find(line => /^\s*BUILD_DIR=/.test(line));
  assert.ok(assignment, `Missing build-directory lookup: ${name}`);
  return assignment.trim();
}

function runLookup(t, step, products, settingsExit = 0, omitSettings = false) {
  const root = mkdtempSync(join(tmpdir(), 'clipped-release-path-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'scripts'));
  mkdirSync(join(root, 'bin'));
  copyFileSync(helper, join(root, 'scripts/build-products-dir.sh'));
  writeFileSync(join(root, 'bin/xcodebuild'), `#!/bin/sh
printf '%s\n' "$@" > "$FAKE_ARGV"
if [ "$OMIT_SETTINGS" != 1 ]; then
  printf '    BUILT_PRODUCTS_DIR = %s\n' "$FAKE_PRODUCTS"
fi
exit "$SETTINGS_EXIT"
`, { mode: 0o755 });
  const env = {
    ...process.env,
    PATH: `${join(root, 'bin')}:${process.env.PATH}`,
    FAKE_PRODUCTS: products,
    SETTINGS_EXIT: String(settingsExit),
    OMIT_SETTINGS: omitSettings ? '1' : '0',
    FAKE_ARGV: join(root, 'argv'),
  };
  // Match Actions' unspecified Linux/macOS shell: bash -e, without pipefail.
  const result = spawnSync('/bin/bash', ['-e', '-c', `${lookupFor(step)}\nprintf 'LOOKUP_OK:%s\n' "$BUILD_DIR"`], {
    cwd: root,
    env,
    encoding: 'utf8',
    timeout: 5000,
  });
  result.xcodeArguments = readFileSync(join(root, 'argv'), 'utf8').trimEnd().split('\n');
  return result;
}

for (const step of ['Notarize app', 'Find artifact']) {
  test(`${step} retains spaces in the actual workflow lookup`, t => {
    const products = '/temporary path/Build Products/Release';
    const result = runLookup(t, step, products);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `LOOKUP_OK:${products}\n`);
    assert.deepEqual(result.xcodeArguments, [
      '-project', 'Clipped/Clipped.xcodeproj', '-scheme', 'Clipped',
      '-configuration', 'Release', '-showBuildSettings',
    ]);
  });
  test(`${step} retains an ordinary path`, t => {
    const result = runLookup(t, step, '/temporary/Build/Release');
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'LOOKUP_OK:/temporary/Build/Release\n');
  });
  test(`${step} stops after failed settings even when stdout contains a path`, t => {
    const result = runLookup(t, step, '/temporary/Build/Release', 31);
    assert.equal(result.status, 31, result.stderr);
    assert.equal(result.stdout.includes('LOOKUP_OK'), false);
  });
  test(`${step} stops when settings omit the product directory`, t => {
    const result = runLookup(t, step, '', 0, true);
    assert.equal(result.status, 1, result.stderr);
    assert.equal(result.stdout.includes('LOOKUP_OK'), false);
    assert.match(result.stderr, /did not report a build products directory/);
  });
}

function homebrewScript() {
  const start = workflow.indexOf('      - name: Update Homebrew tap\n');
  assert.notEqual(start, -1);
  const end = workflow.indexOf('\n      - name:', start + 1);
  const body = workflow.slice(start, end < 0 ? undefined : end).split('        run: |\n')[1];
  assert.ok(body);
  return body.split('\n').map(line => line.startsWith('          ') ? line.slice(10) : line).join('\n')
    .replaceAll('${{ github.ref_name }}', 'v8.9.10')
    .replaceAll('${{ steps.artifact.outputs.sha256 }}', 'a'.repeat(64))
    .replaceAll('${{ steps.artifact.outputs.cask_arches }}', ':arm64');
}

function emittedCask(t, currentSha) {
  const root = mkdtempSync(join(tmpdir(), 'clipped-cask-domain-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'gh'), [
    '#!/bin/sh',
    'printf . >> "$FAKE_GH_CALLS"',
    'if [ "${3-}" = "-q" ]; then',
    '  printf \'%s\\0\' "$@" > "$FAKE_GET_ARGV"',
    '  printf \'%s\\n\' "$FAKE_CURRENT_SHA"',
    'else',
    '  printf \'%s\\0\' "$@" > "$FAKE_WRITE_ARGV"',
    'fi', '',
  ].join('\n'), { mode: 0o755 });
  const env = {
    ...process.env, PATH: `${bin}:/usr/bin:/bin`, HOME: root, CFFIXED_USER_HOME: root, TMPDIR: root,
    GH_TOKEN: 'fixture', GITHUB_TOKEN: 'fixture',
    FAKE_CURRENT_SHA: currentSha, FAKE_GH_CALLS: join(root, 'calls'),
    FAKE_GET_ARGV: join(root, 'get'), FAKE_WRITE_ARGV: join(root, 'write'),
  };
  for (const name of Object.keys(env)) {
    if (['BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS'].includes(name) || name.startsWith('BASH_FUNC_')) delete env[name];
  }
  const script = homebrewScript();
  assert.equal(script.includes('${{'), false);
  const result = spawnSync('/bin/bash', ['-e', '-c', script], {
    cwd: root, env, encoding: 'utf8', timeout: 5000, killSignal: 'SIGKILL',
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
  assert.equal(readFileSync(env.FAKE_GH_CALLS, 'utf8'), '..');
  const args = path => readFileSync(path, 'utf8').split('\0').slice(0, -1);
  const endpoint = 'repos/mcclowes/homebrew-clipped/contents/Casks/clipped.rb';
  assert.deepEqual(args(env.FAKE_GET_ARGV), ['api', endpoint, '-q', '.sha']);
  const write = args(env.FAKE_WRITE_ARGV);
  const content = write.find(arg => arg.startsWith('content='));
  assert.ok(content);
  assert.deepEqual(write, ['api', endpoint, '-X', 'PUT', '-f',
    currentSha ? 'message=Update clipped to v8.9.10' : 'message=Add clipped v8.9.10',
    '-f', content, ...(currentSha ? ['-f', `sha=${currentSha}`] : [])]);
  return Buffer.from(content.slice('content='.length), 'base64').toString('utf8');
}

for (const currentSha of ['fixture-current-sha', '']) {
  test(`${currentSha ? 'Updating' : 'Creating'} a cask and its nightly derivative uses the app preferences domain`, t => {
    const cask = emittedCask(t, currentSha);
    const project = readFileSync(new URL('../Clipped/project.yml', import.meta.url), 'utf8');
    const bundleId = project.match(/PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)/)?.[1];
    assert.ok(bundleId);
    const preference = `~/Library/Preferences/${bundleId}.plist`;
    assert.equal(cask.match(/"(~\/Library\/Preferences\/[^"\n]+)"/)?.[1], preference);
    const nightly = nightlyRecipe(cask, { kind: 'cask', stable: 'clipped', nightly: 'clipped@nightly' }, {
      url: 'https://example.invalid/Clipped.zip', sha256: 'b'.repeat(64), version: '1.0.0', revision: 123,
    });
    assert.equal(nightly.match(/"(~\/Library\/Preferences\/[^"\n]+)"/)?.[1], preference);
    assert.ok(nightly.includes('"~/Library/Application Support/Clipped"'));
  });
}
