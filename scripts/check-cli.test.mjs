import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pinnedPackage, verifyPackage } from './check-cli.mjs';

function fixture(t, { version = '0.10.23', source }) {
  const root = mkdtempSync(join(tmpdir(), 'vibe-cli-gate-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'package.json'), JSON.stringify({
    name: '@vibe-cafe/vibe-usage', version, type: 'module',
    bin: { 'vibe-usage': 'bin/vibe-usage.js' },
  }));
  writeFileSync(join(root, 'bin/vibe-usage.js'), source);
  return root;
}

test('rejects the old npm release before trying to use it as the new pin', t => {
  const root = fixture(t, { source: 'throw new Error("must not execute");' });
  assert.throws(() => verifyPackage(root), /does not match the Mac app pin/);
});

test('a matching version without the quota command is still rejected', t => {
  const root = fixture(t, { source: `
    if (process.argv[2] === 'config') console.log('{}');
    else { console.error('Unknown command: quota'); process.exitCode = 1; }
  ` });
  assert.throws(() => verifyPackage(root, '@vibe-cafe/vibe-usage@0.10.23'), /failed/);
});

test('rejects protocol drift even when every command exits successfully', t => {
  const root = fixture(t, { source: `
    console.log(JSON.stringify(process.argv[2] === 'config'
      ? {} : { schemaVersion: 2, products: [] }));
  ` });
  assert.throws(() => verifyPackage(root, '@vibe-cafe/vibe-usage@0.10.23'), /discovery schema/);
});

test('discovery alone cannot hide a missing Grok fetch adapter', t => {
  const root = fixture(t, { source: `
    const ids = ['kimi-code', 'zcode', 'grok', 'cursor'];
    const result = process.argv[2] === 'config' ? {} : {
      schemaVersion: 1,
      products: process.argv[3] === 'discover'
        ? ids.map(id => ({ id, fetchable: id !== 'cursor' }))
        : ids.slice(0, 2).map(id => ({ id, status: 'missing_credentials', meters: [] })),
    };
    console.log(JSON.stringify(result));
  ` });
  assert.throws(() => verifyPackage(root, '@vibe-cafe/vibe-usage@0.10.23'), assert.AssertionError);
});

test('the production pin is a concrete release, independent of local overrides', () => {
  const previous = process.env.VIBE_USAGE_CLI_PACKAGE;
  try {
    process.env.VIBE_USAGE_CLI_PACKAGE = '/temporary/unpublished-checkout';
    assert.match(pinnedPackage(), /^@vibe-cafe\/vibe-usage@\d+\.\d+\.\d+$/);
  } finally {
    if (previous === undefined) delete process.env.VIBE_USAGE_CLI_PACKAGE;
    else process.env.VIBE_USAGE_CLI_PACKAGE = previous;
  }
});
