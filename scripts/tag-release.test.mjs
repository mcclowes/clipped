import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/tag-release.yml', import.meta.url), 'utf8');
const branchExpression = '${{ github.event.pull_request.head.ref }}';
const tagExpression = '${{ steps.version.outputs.tag }}';

function stepFor(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert.notEqual(start, -1, `Missing workflow step: ${name}`);
  const end = workflow.indexOf('\n      - name:', start + 1);
  const step = workflow.slice(start, end < 0 ? undefined : end);
  const run = step.indexOf('        run: |\n');
  assert.notEqual(run, -1, `Missing shell script: ${name}`);
  return {
    step,
    script: step.slice(run + '        run: |\n'.length)
      .split('\n').map(line => line.replace(/^          /, '')).join('\n'),
  };
}

function runStep(t, name, branch) {
  const validRef = spawnSync('/usr/bin/git', ['check-ref-format', '--branch', branch], { encoding: 'utf8' });
  assert.equal(validRef.status, 0, `Fixture must be a valid Git branch: ${branch}`);
  const root = mkdtempSync(join(tmpdir(), 'clipped-tag-release-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'bin'));
  const marker = join(root, 'shell-evaluated');
  const gitLog = join(root, 'git-argv');
  const output = join(root, 'output');
  writeFileSync(output, '');
  writeFileSync(join(root, 'bin/clipped-branch-probe'), '#!/bin/sh\n: > "$CLIPPED_PROBE_MARKER"\nprintf INJECTED\n', {
    mode: 0o755,
  });
  writeFileSync(join(root, 'bin/git'), '#!/bin/sh\nprintf \'%s\\0\' "$@" >> "$CLIPPED_GIT_ARGV"\nprintf \'\\n\' >> "$CLIPPED_GIT_ARGV"\n', {
    mode: 0o755,
  });
  const { step, script } = stepFor(name);
  const tag = branch.slice('bump/'.length);
  const env = {
    ...process.env,
    PATH: `${join(root, 'bin')}:${process.env.PATH}`,
    BASH_ENV: '/dev/null',
    GITHUB_OUTPUT: output,
    CLIPPED_PROBE_MARKER: marker,
    CLIPPED_GIT_ARGV: gitLog,
    CLIPPED_TEST_LITERAL: 'INJECTED',
  };
  delete env.PR_BRANCH;
  delete env.TAG;
  for (const [, key, value] of step.matchAll(/^ {10}([A-Z][A-Z0-9_]*): (.+)$/gm)) {
    if (value === branchExpression) env[key] = branch;
    if (value === tagExpression) env[key] = tag;
  }
  const result = spawnSync('/bin/bash', ['-e', '-c', script
    .replaceAll(branchExpression, branch).replaceAll(tagExpression, tag)], {
    cwd: root,
    env,
    encoding: 'utf8',
    timeout: 5000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(marker), false, 'Branch text was executed as a shell command');
  return {
    tag,
    output: readFileSync(output, 'utf8'),
    calls: existsSync(gitLog)
      ? readFileSync(gitLog, 'utf8').split('\n').filter(Boolean).map(line => line.split('\0').slice(0, -1))
      : [],
  };
}

for (const branch of [
  'bump/v1.2.3',
  'bump/v1.2.3-rc.1',
  'bump/v$(clipped-branch-probe)',
  'bump/v`clipped-branch-probe`',
  'bump/v$CLIPPED_TEST_LITERAL',
  'bump/v"$(clipped-branch-probe)"',
]) {
  test(`extracts branch text literally: ${branch}`, t => {
    const result = runStep(t, 'Extract version from branch name', branch);
    assert.equal(result.output, `tag=${result.tag}\n`);
    assert.deepEqual(result.calls, []);
  });

  test(`tags and pushes literal arguments: ${branch}`, t => {
    const result = runStep(t, 'Create and push tag', branch);
    assert.deepEqual(result.calls, [
      ['tag', '-a', result.tag, '-m', `Release ${result.tag}`],
      ['push', 'origin', result.tag],
    ]);
  });

  test(`deletes only the literal branch argument: ${branch}`, t => {
    const result = runStep(t, 'Delete bump branch', branch);
    assert.deepEqual(result.calls, [['push', 'origin', '--delete', branch]]);
  });
}
