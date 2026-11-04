import test from 'node:test';
import assert from 'node:assert/strict';
import { attach, apply, inject } from './index.js';
import { registry, job, deferred, nativeFixtures } from './fixtures.mjs';
import { readFileSync } from 'node:fs';

function fixture() {
  const agents = registry(), listeners = new Map(), frames = [], timers = new Map(), jobs = new Map();
  const listCalls = []; let n = 0, stopped = 0, spawned = 0, jobListener, unsubscribed = 0, listHook;
  const ctx = {
    agents: agents.service, subprocess: {},
    jobs: {
      events: { subscribe(filter, callback) {
        assert.deepEqual(filter, { owners: 'all' }); assert.equal(jobListener, undefined);
        jobListener = callback;
        return () => { unsubscribed++; jobListener = undefined; };
      } },
      list(caller) {
        assert.ok(jobListener, 'subscribe must precede baseline list'); listCalls.push(caller);
        const baseline = [...jobs.values()].filter(view => view.owner === undefined || view.owner === caller);
        listHook?.(caller); return baseline;
      },
    },
    on(name, callback, options) {
      assert.equal(listeners.has(name), false); listeners.set(name, { callback, options });
      return () => listeners.delete(name);
    },
  };
  for (const name of ['get', 'read', 'readAt', 'kill', 'remove', 'wait', 'start', 'attachController']) {
    Object.defineProperty(ctx.jobs, name, { get() { throw new Error(`Forbidden jobs API: ${name}`); } });
  }
  const clock = { setTimeout(fn, delay) { assert.equal(delay, 200); timers.set(++n, fn); return n; }, clearTimeout(id) { timers.delete(id); } };
  const createBridge = (subprocess, initial) => {
    assert.equal(subprocess, ctx.subprocess); spawned++; frames.push(initial);
    return { publish(frame) { frames.push(frame); }, async dispose() { stopped++; } };
  };
  return { ...agents, ctx, listeners, frames, timers, jobs, listCalls,
    emit: (name, ...args) => listeners.get(name).callback(...args),
    emitJob: event => jobListener?.(event),
    start: (overrides = {}) => attach(ctx, { createBridge, clock, ...overrides }),
    fire() { for (const [id, callback] of [...timers]) { timers.delete(id); callback(); } },
    setListHook(hook) { listHook = hook; },
    get spawned() { return spawned; }, get stopped() { return stopped; }, get unsubscribed() { return unsubscribed; },
  };
}

test('named apply and exact mandatory service injection', () => {
  assert.equal(typeof apply, 'function'); assert.deepEqual(inject, ['agents', 'jobs', 'subprocess']);
});
test('created/status/disposed track exact roots and children; topology never rescans on status/jobs', async () => {
  const f = fixture(), cleanup = f.start();
  assert.equal(f.spawned, 1); assert.equal(f.frames[0].activeChats, 0); assert.equal(f.frames[0].activeJobs, 0);
  const root = f.add(), child = f.add('running', root), nested = f.add('running', child);
  f.emit('agent/created', { agent: root });
  let last = f.frames.at(-1); assert.equal(last.activeChats, 1); assert.equal(last.activeSubagents, 2);
  const calls = { ...f.calls };
  f.emit('agent/status', { agent: root, status: 'running' });
  f.emit('agent/status', { agent: child, status: 'idle' });
  f.emitJob({ type: 'registered', job: job('actual-registry-job', nested.id) });
  assert.deepEqual(f.calls, calls);
  last = f.frames.at(-1); assert.equal(last.activeSubagents, 1); assert.equal(last.activeJobs, 1);
  f.emitJob({ type: 'settled', job: job('actual-registry-job', nested.id, 'completed') });
  f.remove(nested); f.emit('agent/disposed', { agent: nested });
  f.remove(root); f.emit('agent/disposed', { agent: root });
  assert.equal(f.frames.at(-1).activeChats, 0);
  await cleanup(); assert.equal(f.stopped, 1); assert.equal(f.listeners.size, 0); assert.equal(f.unsubscribed, 1);
});
test('baseline lists unowned and every live agent, dedupes jobs and never reads labels/output', async () => {
  const f = fixture(), root = f.add(), child = f.add('running', root), other = f.add();
  for (const view of [job('u'), job('r', root.id), job('c', child.id, 'stopping'), job('done', other.id, 'completed')]) f.jobs.set(view.id, view);
  const cleanup = f.start(), initial = f.frames[0];
  assert.deepEqual(f.listCalls, [undefined, root.id, child.id, other.id]);
  assert.equal(initial.activeJobs, 3); assert.equal(initial.activeChats, 1); assert.equal(initial.activeSubagents, 1);
  const minis = initial.pets.filter(p => p.role === 'job');
  assert.equal(minis.filter(p => p.parent === null).length, 1);
  assert.equal(minis.filter(p => p.parent === 's0').length, 2);
  assert.ok(!JSON.stringify(initial).includes('private'));
  await cleanup();
});
test('true background registration immediately after existing baseline needs no timer or rescan', async () => {
  const f = fixture(), root = f.add(); f.jobs.set('existing', job('existing', root.id));
  const cleanup = f.start(), listCalls = f.listCalls.length;
  assert.equal(f.frames.at(-1).activeJobs, 1);
  f.emitJob({ type: 'registered', job: job('new-background', root.id, 'running', 2) });
  assert.equal(f.frames.at(-1).activeJobs, 2); assert.equal(f.frames.at(-1).activeChats, 1);
  assert.equal(f.timers.size, 0); assert.equal(f.listCalls.length, listCalls);
  f.emitJob({ type: 'stopping', job: job('new-background', root.id, 'stopping', 2) });
  assert.equal(f.frames.at(-1).activeJobs, 2);
  f.emitJob({ type: 'settled', job: job('new-background', root.id, 'killed', 2), cause: 'kill', awaited: false });
  assert.equal(f.frames.at(-1).activeJobs, 1);
  f.emitJob({ type: 'removed', job: job('existing', root.id, 'completed') });
  assert.equal(f.frames.at(-1).activeJobs, 0); assert.equal(f.frames.at(-1).activeChats, 0);
  await cleanup();
});
for (const eventType of ['registered', 'progress', 'stopping', 'settled', 'removed']) test(`subscribe-first ${eventType} race beats stale baseline`, async () => {
  const f = fixture(), root = f.add(); f.jobs.set('racy', job('racy', root.id));
  let emitted = false;
  f.setListHook(caller => {
    if (caller !== root.id || emitted) return;
    emitted = true;
    const status = eventType === 'settled' || eventType === 'removed' ? 'completed' : eventType === 'stopping' ? 'stopping' : 'running';
    f.emitJob({ type: eventType, job: job('racy', root.id, status) });
  });
  const cleanup = f.start();
  assert.equal(f.frames[0].activeJobs, eventType === 'settled' || eventType === 'removed' ? 0 : 1);
  await cleanup();
});
test('registration followed by settlement while baseline seeds cannot resurrect a job', async () => {
  const f = fixture(); f.jobs.set('racy', job('racy'));
  f.setListHook(() => {
    f.emitJob({ type: 'registered', job: job('racy') });
    f.emitJob({ type: 'settled', job: job('racy', undefined, 'completed') });
  });
  const cleanup = f.start(); assert.equal(f.frames[0].activeJobs, 0); await cleanup();
});
test('output/progress-only churn is ignored, but progress carrying terminal status is honored', async () => {
  const f = fixture(); f.jobs.set('live', job('live'));
  const cleanup = f.start(), count = f.frames.length, calls = { ...f.calls };
  for (let i = 0; i < 100; i++) {
    const output = { type: 'output' };
    Object.defineProperty(output, 'job', { get() { throw new Error('output events have no job view'); } });
    f.emitJob(output); f.emitJob({ type: 'progress', job: job('live') });
  }
  assert.equal(f.frames.length, count); assert.deepEqual(f.calls, calls);
  f.emitJob({ type: 'progress', job: job('live', undefined, 'failed') });
  assert.equal(f.frames.at(-1).activeJobs, 0);
  f.emitJob({ type: 'progress', job: job('live') });
  assert.equal(f.frames.at(-1).activeJobs, 0); await cleanup();
});
test('unknown-owner event is an unparented job; reused root ID cannot steal old root binding', async () => {
  const f = fixture(), old = f.add('idle', undefined, 'same-id'), cleanup = f.start();
  f.emitJob({ type: 'registered', job: job('owned', old.id) });
  f.emitJob({ type: 'registered', job: job('unknown', 'unknown-session') });
  const first = f.frames.at(-1).pets.filter(p => p.role === 'job');
  f.remove(old); f.emit('agent/disposed', { agent: old });
  const fresh = f.add('running', undefined, old.id); f.emit('agent/created', { agent: fresh });
  const last = f.frames.at(-1); assert.equal(last.activeChats, 2);
  assert.deepEqual(last.pets.filter(p => p.role === 'job'), first);
  assert.equal(first[1].parent, null); await cleanup();
});
test('both prepended waterfalls preserve exact outcomes with deduped 200ms attention', async () => {
  const f = fixture(), root = f.add('running'), cleanup = f.start();
  const pending = [deferred(), deferred()], answers = [{ answers: [] }, 'allowed-once'];
  const requests = ['user-questions/request', 'approval/request'].map((name, i) => {
    assert.deepEqual(f.listeners.get(name).options, { prepend: true }); let calls = 0;
    const result = f.emit(name, { agent: root }, () => { calls++; return pending[i].promise; });
    assert.equal(calls, 1); return result;
  });
  assert.equal(f.frames.at(-1).waitingChats, 0); f.fire(); assert.equal(f.frames.at(-1).waitingChats, 1);
  pending[0].resolve(answers[0]); assert.equal(await requests[0], answers[0]);
  assert.equal(f.frames.at(-1).waitingChats, 1);
  f.remove(root); f.emit('agent/disposed', { agent: root });
  assert.equal(f.frames.at(-1).activeChats, 0); assert.equal(f.timers.size, 0);
  pending[1].resolve(answers[1]); assert.equal(await requests[1], answers[1]); await cleanup();
});
test('teardown unsubscribes jobs/agents, cancels pending attention, owns helper only, preserves answer chain', async () => {
  for (const visible of [false, true]) {
    const f = fixture(), root = f.add(), cleanup = f.start(), pending = deferred();
    const result = f.emit('approval/request', { agent: root }, () => pending.promise);
    f.emitJob({ type: 'registered', job: job('registry-work', root.id) });
    if (visible) f.fire();
    const first = cleanup(); assert.equal(cleanup(), first); await first;
    const count = f.frames.length; f.fire();
    f.emitJob({ type: 'registered', job: job('late') });
    pending.resolve('rejected'); assert.equal(await result, 'rejected');
    assert.equal(f.frames.length, count); assert.equal(f.listeners.size, 0); assert.equal(f.unsubscribed, 1);
    assert.equal(f.timers.size, 0); assert.equal(f.stopped, 1);
  }
});
test('startup failure unwinds both event registries without leaked observers', () => {
  const f = fixture();
  assert.throws(() => f.start({ createBridge() { throw new Error('bridge test failure'); } }), /bridge test failure/);
  assert.equal(f.listeners.size, 0); assert.equal(f.unsubscribed, 1);
});
test('stream/history are never observed; activity follows full running interval', async () => {
  const f = fixture(), root = f.add('running'), cleanup = f.start();
  assert.equal(f.listeners.has('llm/stream'), false); assert.equal(f.listeners.has('agent/assistant-stream'), false);
  assert.equal(f.listeners.has('session/event'), false);
  assert.equal(f.frames.at(-1).pets[0].mode, 'thinking');
  f.emit('agent/status', { agent: root, status: 'idle' });
  assert.equal(f.frames.at(-1).pets[0].mode, 'idle'); await cleanup();
});
test('native test fixtures are exact generated v3, anonymous and count-consistent', () => {
  const fixtures = JSON.parse(readFileSync(new URL('./native-fixtures.json', import.meta.url), 'utf8'));
  assert.deepEqual(fixtures, nativeFixtures());
  for (const frame of fixtures) {
    assert.equal(frame.activeChats, frame.pets.filter(p => p.role === 'session' && p.mode !== 'idle').length);
    assert.equal(frame.waitingChats, frame.pets.filter(p => p.role === 'session' && p.mode === 'awaiting').length);
    assert.equal(frame.activeSubagents, frame.pets.filter(p => p.role === 'subagent').length);
    assert.equal(frame.activeJobs, frame.pets.filter(p => p.role === 'job').length);
    for (const pet of frame.pets) {
      assert.match(pet.id, /^(s|a|j)\d+$/);
      if (pet.parent !== null) assert.equal(pet.style, frame.pets.find(parent => parent.id === pet.parent).style);
    }
  }
});
