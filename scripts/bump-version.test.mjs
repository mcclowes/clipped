import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const script = readFileSync(new URL('./bump-version.sh', import.meta.url), 'utf8');
const original = 'settings:\n  MARKETING_VERSION: "1.2.3"\n';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'clipped-bump-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'Clipped'));
  mkdirSync(join(root, 'bin'));
  const project = join(root, 'Clipped/project.yml');
  writeFileSync(project, original);
  const helper = join(root, 'bump-version.sh');
  writeFileSync(helper, script);
  const gitLog = join(root, 'git.log');
  const git = join(root, 'bin/git');
  writeFileSync(git, '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CLIPPED_BUMP_GIT_LOG"\n');
  chmodSync(git, 0o755);
  const run = args => spawnSync('/bin/bash', [helper, ...args], {
    cwd: root,
    env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, BASH_ENV: '/dev/null', CLIPPED_BUMP_GIT_LOG: gitLog },
    encoding: 'utf8',
    timeout: 5000,
  });
  const calls = () => existsSync(gitLog) ? readFileSync(gitLog, 'utf8').trim().split('\n') : [];
  return { project, run, calls };
}

test('an unknown second argument is rejected before metadata or Git changes', t => {
  const { project, run, calls } = fixture(t);
  const result = run(['patch', '--dry-run']);
  assert.equal(result.error, undefined);
  assert.equal(result.status, 2, JSON.stringify({ metadata: readFileSync(project, 'utf8'), gitCalls: calls() }));
  assert.match(result.stderr, /Usage:/);
  assert.equal(result.stdout, '');
  assert.equal(readFileSync(project, 'utf8'), original);
  assert.deepEqual(calls(), []);
});

for (const args of [
  [], [''], ['--push'], ['unknown'], ['PATCH'], ['patch', ''], ['patch', 'push'],
  ['minor', '--push-now'], ['patch', '--push', 'extra'], ['major', 'extra', '--push'],
  ['minor', '--push', '--push'],
]) {
  test(`rejects malformed arguments ${JSON.stringify(args)} without mutations`, t => {
    const { project, run, calls } = fixture(t);
    const result = run(args);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage:/);
    assert.equal(result.stdout, '');
    assert.equal(readFileSync(project, 'utf8'), original);
    assert.deepEqual(calls(), []);
  });
}

test('invalid arguments are rejected before reading missing project metadata', t => {
  const { project, run, calls } = fixture(t);
  rmSync(project);
  const result = run(['patch', '--dry-run']);
  assert.equal(result.error, undefined);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /Usage:/);
  assert.doesNotMatch(result.stderr, /MARKETING_VERSION|No such file/);
  assert.deepEqual(calls(), []);
});

for (const [bump, version] of [['major', '2.0.0'], ['minor', '1.3.0'], ['patch', '1.2.4']]) {
  for (const push of [false, true]) {
    test(`${bump} preserves version and Git behavior${push ? ' with --push' : ''}`, t => {
      const { project, run, calls } = fixture(t);
      const result = run([bump, ...(push ? ['--push'] : [])]);
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stderr, '');
      assert.equal(readFileSync(project, 'utf8'), original.replace('1.2.3', version));
      assert.ok(result.stdout.includes(`Bumping version: 1.2.3 -> ${version} (${bump})`));
      assert.deepEqual(calls(), [
        'add Clipped/project.yml',
        `commit -m Bump version to ${version}`,
        `tag -a v${version} -m Release v${version}`,
        ...(push ? ['push origin HEAD', `push origin v${version}`] : []),
      ]);
    });
  }
}
