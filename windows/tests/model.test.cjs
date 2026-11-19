const { test } = require('node:test');
const assert = require('node:assert/strict');
const { dayKey, newRow, normalize, progress } = require('../model.js');

test('calendar keys use local dates', () => {
  assert.equal(dayKey(new Date(2026, 10, 20, 23, 50)), '2026-11-20');
});

test('only written child tasks survive serialization', () => {
  const parent = newRow('写完周报');
  const child = { ...newRow('核对数字', parent.id), done: true };
  const rows = [parent, newRow('  ', parent.id), child];
  const data = normalize({ plans: { '2026-11-20': rows, '2026-11-21': [newRow()] }, preferences: { sound: false } });
  assert.deepEqual(data.plans, { '2026-11-20': [parent, child] });
  assert.deepEqual(progress(rows), { done: 1, total: 2 });
  assert.equal(data.preferences.sound, false);
  assert.equal(data.preferences.fontSize, 19);
});

test('malformed snapshots are rejected before overwriting local data', () => {
  assert.throws(() => normalize({ plans: [] }));
  assert.throws(() => normalize({ plans: { '2026-11-20': [null] } }));
});
