import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

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
