import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough, Writable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge, EXECUTABLE, ROOT, STATUS_PATH, MAX_LINE_BYTES, MAX_DIAGNOSTIC_BYTES } from './bridge.js';
const initial = { version: 3, activeChats: 1, waitingChats: 0, activeSubagents: 0, activeJobs: 0, pets: [0, 1, 2].map(i => ({ id: `s${i}`, role: 'session', parent: null, style: i, mode: i ? 'idle' : 'thinking', epoch: i ? 0 : 1 })) };
const awaiting = { ...initial, waitingChats: 1, pets: [{ ...initial.pets[0], mode: 'awaiting' }, ...initial.pets.slice(1)] };
function fixture() {
  let resolve, reject, terminated = 0, spec;
  const frames = [], records = [];
  const stdin = new Writable({ write(chunk, _encoding, done) { frames.push(String(chunk)); done(); } });
  const handle = { stdin, stdout: new PassThrough(), stderr: new PassThrough(), done: new Promise((r, j) => { resolve = r; reject = j; }), terminate() { terminated++; resolve({ exitCode: 0, signal: null }); } };
  const service = { spawn(value) { spec = value; return handle; } };
  return { handle, frames, records, service, resolve, reject, writeStatus: text => records.push(JSON.parse(text)), get spec() { return spec; }, get terminated() { return terminated; } };
}
test('helper stays package-relative while diagnostics use writable per-host temporary storage', async () => {
  assert.equal(EXECUTABLE, fileURLToPath(new URL('../app/DSH Window Cat.app/Contents/MacOS/DSHWindowCat', import.meta.url)));
  assert.equal(ROOT, fileURLToPath(new URL('../', import.meta.url)));
  assert.equal(STATUS_PATH.href, pathToFileURL(join(tmpdir(), 'dsh-pets', String(process.pid), 'status.json')).href);
  assert.ok(!fileURLToPath(STATUS_PATH).startsWith(ROOT));
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  assert.deepEqual(f.spec, { argv: [EXECUTABLE], cwd: ROOT, graceMs: 1500, stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' } });
  await bridge.dispose();
});
test('baseline, frame deduplication, native diagnostics, and idempotent owned shutdown', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  bridge.publish(initial); bridge.publish(awaiting);
  assert.equal(f.frames.length, 2); assert.deepEqual(JSON.parse(f.frames[0]), initial);
  f.handle.stdout.write('{"type":"ready","pid":123,"accessibility":true}\n');
  f.handle.stdout.write('{"type":"tracking","visible":true,"reason":"tracking"}\n');
  const first = bridge.dispose(), second = bridge.dispose();
  assert.equal(first, second); await first; bridge.publish(initial);
  assert.equal(f.frames.length, 2); assert.equal(f.terminated, 1);
  assert.equal(f.handle.stdin.writableEnded, true);
  assert.equal(f.handle.stdout.listenerCount('data'), 0); assert.equal(f.handle.stderr.listenerCount('data'), 0);
  assert.equal(f.handle.stdin.listenerCount('drain'), 0);
  assert.equal(f.records.at(-1).phase, 'stopped'); assert.equal(f.records.at(-1).tracking.visible, true);
  assert.deepEqual(f.records.at(-1).activity, awaiting);
  const recordCount = f.records.length;
  f.handle.stdin.emit('error', new Error('late pipe event'));
  f.handle.stdout.emit('error', new Error('late output event'));
  await bridge.dispose(); assert.equal(f.records.length, recordCount);
});
test('backpressure coalesces to latest state and sends it only on drain', async () => {
  const f = fixture(), stdin = new EventEmitter(); let blocked = true;
  stdin.write = frame => { f.frames.push(frame); return !blocked; };
  stdin.end = () => {}; f.handle.stdin = stdin;
  const bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  bridge.publish(awaiting); bridge.publish({ ...awaiting, activeChats: 4 });
  assert.equal(f.frames.length, 1);
  blocked = false; stdin.emit('drain');
  assert.equal(f.frames.length, 2);
  assert.equal(JSON.parse(f.frames[1]).activeChats, 4);
  await bridge.dispose();
});
test('fragmented, non-JSON and oversized output is bounded and recovers', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  f.handle.stdout.write('x'.repeat(MAX_LINE_BYTES + 1));
  f.handle.stdout.write('discard\nnull\nnot json\n{"type":"rea'); f.handle.stdout.write('dy","pid":7}\n');
  for (let i = 0; i < 50; i++) f.handle.stdout.write(JSON.stringify({ type: 'tracking', visible: false, index: i }) + '\n');
  await bridge.dispose(); const status = f.records.at(-1);
  assert.equal(status.helper.pid, 7); assert.equal(status.tracking.index, 49); assert.ok(status.events.length <= 24);
});
test('dynamic frames exceed the old 8KiB bound but never the 1MiB wire cap', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  const many = { ...initial, activeJobs: 500, pets: [...initial.pets, ...Array.from({ length: 500 }, (_, i) => ({ id: `j${i}`, role: 'job', parent: null, style: i, mode: 'thinking', epoch: 0 }))] };
  assert.ok(Buffer.byteLength(JSON.stringify(many)) > 8192);
  bridge.publish(many); assert.equal(f.frames.length, 2);
  const giant = { ...many, pets: Array.from({ length: 20000 }, (_, i) => ({ ...many.pets[3], id: `j${i}` })) };
  bridge.publish(giant); assert.equal(f.frames.length, 2);
  await bridge.dispose(); const status = f.records.at(-1);
  assert.deepEqual(status.activity, many);
  assert.ok(status.events.some(e => e.type === 'activity-too-large'));
  assert.ok(status.events.filter(e => e.type === 'activity').every(e => typeof e.pets === 'number'));
  assert.ok(Buffer.byteLength(JSON.stringify(status)) < MAX_LINE_BYTES + 30 * MAX_DIAGNOSTIC_BYTES);
});
test('diagnostic envelopes stay small and multiline multibyte oversize recovers', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  f.handle.stdout.write(JSON.stringify({ type: 'stats', pets: 'x'.repeat(300000) }) + '\n');
  f.handle.stdout.write(JSON.stringify({ type: 'tracking', visible: true, text: 'x'.repeat(20000) }) + '\n');
  f.handle.stdout.write('é'.repeat(MAX_LINE_BYTES / 2 + 1));
  f.handle.stdout.write('\n{"type":"ready","pid":9}\n');
  await bridge.dispose(); const status = f.records.at(-1);
  assert.equal(status.helper.pid, 9); assert.deepEqual(status.tracking, { type: 'tracking', truncated: true });
  assert.ok(status.events.some(e => e.type === 'stats' && e.truncated));
  for (const event of status.events) assert.ok(Buffer.byteLength(JSON.stringify(event)) < MAX_DIAGNOSTIC_BYTES + 100);
});
test('slow diagnostic persistence coalesces snapshots rather than queuing unbounded writes', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = fixture(), records = [], releases = [];
  const bridge = startBridge(f.service, initial, { writeStatus(text) { records.push(JSON.parse(text)); return new Promise(resolve => releases.push(resolve)); } });
  t.mock.timers.tick(100); await Promise.resolve();
  assert.equal(records.length, 1);
  for (let i = 0; i < 100; i++) {
    bridge.publish({ ...initial, activeChats: i }); t.mock.timers.tick(100);
  }
  assert.equal(records.length, 1);
  releases.shift()(); await Promise.resolve();
  assert.equal(records.length, 2); assert.equal(records[1].activity.activeChats, 99);
  const disposed = bridge.dispose(); await Promise.resolve();
  releases.shift()(); await Promise.resolve();
  if (releases.length) releases.shift()();
  await disposed;
  assert.equal(records.at(-1).phase, 'stopped');
});
test('failed spawn is contained and persisted', async () => {
  const records = [], bridge = startBridge({ spawn() { throw new Error('not executable'); } }, initial, { writeStatus: text => records.push(JSON.parse(text)) });
  bridge.publish(initial); await bridge.dispose(); assert.equal(records.at(-1).phase, 'spawn-failed');
});
test('broken stdin and output stream errors are contained', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  f.handle.stdin.emit('error', Object.assign(new Error('closed'), { code: 'EPIPE' }));
  f.handle.stdout.emit('error', Object.assign(new Error('read'), { code: 'EIO' }));
  bridge.publish(awaiting); assert.equal(f.frames.length, 1);
  await bridge.dispose(); assert.equal(f.terminated, 1);
  assert.ok(f.records.at(-1).events.some(e => e.code === 'EPIPE'));
  assert.ok(f.records.at(-1).events.some(e => e.code === 'EIO'));
});
test('closed stdin prevents writes even when a late drain arrives', async () => {
  const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
  f.handle.stdin.emit('close'); bridge.publish(awaiting); f.handle.stdin.emit('drain');
  assert.equal(f.frames.length, 1); await bridge.dispose();
});
test('natural exit and rejected process outcome stop writes without terminating another process', async () => {
  for (const failed of [false, true]) {
    const f = fixture(), bridge = startBridge(f.service, initial, { writeStatus: f.writeStatus });
    if (failed) f.reject(new Error('provider failure')); else f.resolve({ exitCode: 1, signal: null });
    await Promise.resolve(); bridge.publish(awaiting);
    assert.equal(f.frames.length, 1); await bridge.dispose(); assert.equal(f.terminated, 0);
    assert.ok(f.records.at(-1).events.some(e => e.type === (failed ? 'process-error' : 'exit')));
  }
});
