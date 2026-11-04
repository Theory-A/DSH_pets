import test from 'node:test';
import assert from 'node:assert/strict';
import { Activity, observeInteraction } from './activity.js';
import { job } from './fixtures.mjs';

function registry() {
  const entries = new Map();
  const calls = { list: 0, roots: 0, ownership: 0 };
  const service = {
    list() { calls.list++; return [...entries.keys()]; },
    roots() { calls.roots++; return [...entries].filter(([, owner]) => !owner).map(([agent]) => agent); },
    isOwnedBy(id, owner) { calls.ownership++; return [...entries].some(([agent, parent]) => agent.id === id && parent === owner); },
  };
  let serial = 0;
  const add = (status = 'idle', owner, id = `private-${++serial}`) => {
    const agent = { id, status, secret: 'message must not leave host' };
    entries.set(agent, owner);
    return agent;
  };
  return { service, calls, add, remove: agent => entries.delete(agent) };
}
const modes = activity => activity.snapshot().pets.filter(pet => pet.role === 'session').map(pet => pet.mode);
function fixture(status = 'running') {
  const registryState = registry(), agent = registryState.add(status);
  const callbacks = new Map(); let n = 0, alive = true, publications = 0;
  const env = { activity: new Activity(registryState.service), publish: () => publications++, active: () => alive, cleanups: new Set() };
  const clock = { setTimeout(fn, delay) { assert.equal(delay, 200); callbacks.set(++n, fn); return n; }, clearTimeout(id) { callbacks.delete(id); } };
  return { ...registryState, agent, env, clock,
    fire() { for (const [id, fn] of [...callbacks]) { callbacks.delete(id); fn(); } },
    stop() { alive = false; for (const cancel of [...env.cleanups]) cancel(); },
    get publications() { return publications; }, get timers() { return callbacks.size; } };
}
function deferred() { let resolve, reject; const promise = new Promise((r, j) => { resolve = r; reject = j; }); return { promise, resolve, reject }; }

for (let count = 0; count <= 10; count++) test(`${count} active roots have exact v3 counts and cycling styles`, () => {
  const f = registry(); for (let i = 0; i < count; i++) f.add('running');
  const activity = new Activity(f.service), snapshot = activity.snapshot();
  assert.equal(snapshot.version, 3);
  assert.equal(snapshot.activeChats, count); assert.equal(snapshot.waitingChats, 0);
  assert.equal(snapshot.activeSubagents, 0); assert.equal(snapshot.activeJobs, 0);
  assert.equal(snapshot.pets.length, Math.max(count, 3));
  assert.equal(snapshot.pets.filter(p => p.mode === 'thinking').length, count);
  snapshot.pets.forEach((p, i) => {
    assert.equal(p.id, `s${i}`); assert.equal(p.style, i);
    assert.equal(p.style % 3, i % 3); assert.equal(Math.floor(p.style / 3), Math.floor(i / 3));
  });
  assert.deepEqual(activity.snapshot(), snapshot);
});
test('nested descendants count as ONE runtime root; statuses never query topology', () => {
  const f = registry(), root = f.add(), child = f.add('running', root), nested = f.add('running', child);
  const state = new Activity(f.service);
  assert.equal(state.snapshot().activeChats, 1);
  const calls = { ...f.calls };
  state.status(root, 'running'); state.status(child, 'idle'); state.status(nested, 'idle');
  assert.equal(state.snapshot().activeChats, 1);
  state.status(root, 'idle');
  assert.equal(state.snapshot().activeChats, 0);
  assert.deepEqual(f.calls, calls);
});
test('removed intermediate parent and root preserve cached nested descendant association', () => {
  const f = registry(), root = f.add(), child = f.add('idle', root), grandchild = f.add('running', child);
  const state = new Activity(f.service), first = state.snapshot();
  f.remove(child); state.disposed(child);
  assert.deepEqual(state.snapshot(), first);
  f.remove(root); state.disposed(root);
  assert.deepEqual(state.snapshot(), first);
  const nestedOrphan = f.add('running', grandchild); state.created(nestedOrphan);
  assert.equal(state.snapshot().activeChats, 1);
  assert.equal(state.rootOf.get(nestedOrphan), root);
  f.remove(grandchild); state.disposed(grandchild);
  assert.equal(state.snapshot().activeChats, 1);
  f.remove(nestedOrphan); state.disposed(nestedOrphan);
  assert.equal(state.snapshot().activeChats, 0);
});
test('unknown orphan at startup is not invented as a new root', () => {
  const f = registry(); f.add('running', { id: 'missing-parent' });
  const state = new Activity(f.service);
  assert.equal(state.snapshot().activeChats, 0);
});
test('same-ID recreation has a fresh binding; late old status and disposal cannot affect it', () => {
  const f = registry(), old = f.add('running', undefined, 'reused');
  const state = new Activity(f.service), start = state.snapshot();
  f.remove(old); state.disposed(old);
  const released = state.snapshot();
  assert.equal(released.pets[0].epoch, start.pets[0].epoch + 1);
  const fresh = f.add('running', undefined, 'reused'); state.created(fresh);
  const replacement = state.snapshot();
  assert.equal(replacement.pets[0].epoch, released.pets[0].epoch + 1);
  state.status(old, 'idle'); state.status(old, 'running'); state.disposed(old);
  assert.deepEqual(state.snapshot(), replacement);
});
test('orphan from old root never migrates to a new root with a reused ID', () => {
  const f = registry(), old = f.add('idle', undefined, 'same'), child = f.add('running', old);
  const state = new Activity(f.service); state.snapshot();
  f.remove(old); state.disposed(old);
  const fresh = f.add('running', undefined, 'same'); state.created(fresh);
  assert.equal(state.snapshot().activeChats, 2);
  assert.equal(state.rootOf.get(child), old);
  assert.equal(state.rootOf.get(fresh), fresh);
});
test('bindings remain stable after a different root completes and releases increment epochs', () => {
  const f = registry(), a = f.add('running'), b = f.add('running'), c = f.add('running');
  const state = new Activity(f.service), first = state.snapshot();
  state.status(b, 'idle');
  const second = state.snapshot();
  assert.equal(state.bindings[0], a); assert.equal(state.bindings[2], c);
  assert.equal(second.pets[1].mode, 'idle');
  assert.equal(second.pets[1].epoch, first.pets[1].epoch + 1);
  assert.equal(second.pets[0].epoch, first.pets[0].epoch);
  const d = f.add('running'); state.created(d); state.snapshot();
  assert.deepEqual(state.bindings, [a, d, c]);
});
test('waiting deduplicates root/children, replaces thinking, and pending-only roots are active', () => {
  const f = registry(), root = f.add('running'), child = f.add('running', root), second = f.add();
  const state = new Activity(f.service), before = state.snapshot();
  const tokens = [Symbol(), Symbol(), Symbol()];
  state.begin(tokens[0], root); state.begin(tokens[1], child); state.begin(tokens[2], second);
  const waiting = state.snapshot();
  assert.equal(waiting.activeChats, 2); assert.equal(waiting.waitingChats, 2);
  assert.deepEqual(waiting.pets.filter(p => p.role === 'session').map(cat => cat.mode), ['awaiting', 'awaiting', 'idle']);
  assert.equal(waiting.pets[0].epoch, before.pets[0].epoch);
  state.end(tokens[0]); assert.equal(state.snapshot().waitingChats, 2);
  state.end(tokens[1]); assert.equal(state.snapshot().waitingChats, 1);
  state.end(tokens[2]); assert.deepEqual(modes(state), ['thinking', 'idle', 'idle']);
});
test('waiting beyond three never evicts or renumbers other active bindings', () => {
  const f = registry(), roots = Array.from({ length: 10 }, () => f.add('running'));
  const state = new Activity(f.service), before = state.snapshot(), bindings = [...state.bindings];
  for (const root of roots.slice(4)) state.begin(Symbol(), root);
  const after = state.snapshot();
  assert.equal(after.activeChats, 10); assert.equal(after.waitingChats, 6);
  assert.deepEqual(state.bindings, bindings);
  assert.deepEqual(after.pets.map(p => p.epoch), before.pets.map(p => p.epoch));
  for (let i = 0; i < 10; i++) assert.deepEqual(state.snapshot(), after);
});
test('snapshot contains exactly anonymous v3 fields', () => {
  const f = fixture(); f.env.activity.begin(Symbol(), f.agent);
  const snapshot = f.env.activity.snapshot();
  assert.deepEqual(Object.keys(snapshot), ['version', 'activeChats', 'waitingChats', 'activeSubagents', 'activeJobs', 'pets']);
  for (const cat of snapshot.pets) assert.deepEqual(Object.keys(cat), ['id', 'role', 'parent', 'style', 'mode', 'epoch']);
  assert.ok(!JSON.stringify(snapshot).includes('private'));
  assert.ok(!JSON.stringify(snapshot).includes('message'));
});
test('delayed request calls next exactly once and preserves exact answer identity', async () => {
  const f = fixture(), d = deferred(), answer = { answers: [] }; let calls = 0;
  const result = observeInteraction({ agent: f.agent }, () => { calls++; return d.promise; }, f.env, f.clock);
  assert.equal(f.env.activity.snapshot().waitingChats, 0); f.fire();
  assert.equal(f.env.activity.snapshot().waitingChats, 1);
  d.resolve(answer); assert.equal(await result, answer); assert.equal(calls, 1);
  assert.equal(f.env.activity.snapshot().waitingChats, 0); assert.equal(f.env.cleanups.size, 0);
});
test('instant answer and sync/async errors preserve outcomes without attention', async () => {
  const f = fixture(), error = new Error('authority error');
  assert.equal(await observeInteraction({ agent: f.agent }, () => 'allowed-once', f.env, f.clock), 'allowed-once');
  assert.throws(() => observeInteraction({ agent: f.agent }, () => { throw error; }, f.env, f.clock), e => e === error);
  await assert.rejects(observeInteraction({ agent: f.agent }, () => Promise.reject(error), f.env, f.clock), e => e === error);
  f.fire(); assert.equal(f.publications, 0); assert.equal(f.timers, 0);
});
test('abort before and after delay clears attention without fabricating a result', async () => {
  for (const fire of [false, true]) {
    const f = fixture(), controller = new AbortController(), d = deferred(), error = new Error('cancelled');
    const p = observeInteraction({ agent: f.agent, signal: controller.signal }, () => d.promise, f.env, f.clock);
    if (fire) f.fire(); controller.abort(); f.fire();
    assert.equal(f.env.activity.snapshot().waitingChats, 0); assert.equal(f.env.cleanups.size, 0);
    d.reject(error); await assert.rejects(p, e => e === error);
  }
});
test('already aborted, unknown, agentless and stale-ID requests never fabricate chats', async () => {
  const f = fixture('idle'), controller = new AbortController(); controller.abort();
  for (const request of [{ agent: f.agent, signal: controller.signal }, {}, { agent: { id: f.agent.id } }]) {
    const d = deferred(); let calls = 0;
    const p = observeInteraction(request, () => { calls++; return d.promise; }, f.env, f.clock);
    f.fire(); assert.equal(f.env.activity.snapshot().activeChats, 0);
    d.resolve('unavailable'); assert.equal(await p, 'unavailable'); assert.equal(calls, 1);
  }
});
test('disposal before delay cannot revive an indicator; unload preserves later result', async () => {
  const f = fixture(), d = deferred();
  const p = observeInteraction({ agent: f.agent }, () => d.promise, f.env, f.clock);
  f.remove(f.agent); f.env.activity.disposed(f.agent); f.fire();
  assert.equal(f.env.activity.snapshot().activeChats, 0);
  f.stop(); assert.equal(f.env.cleanups.size, 0);
  d.resolve('rejected'); assert.equal(await p, 'rejected');
  const g = fixture(), e = deferred();
  const q = observeInteraction({ agent: g.agent }, () => e.promise, g.env, g.clock);
  g.fire(); g.stop(); assert.equal(g.env.activity.snapshot().waitingChats, 0);
  e.resolve('cancelled'); assert.equal(await q, 'cancelled');
});
test('extra slots disappear on release, keep holes, and reuse lowest free slot with epoch history', () => {
  const f = registry(), roots = Array.from({ length: 7 }, () => f.add('running'));
  const state = new Activity(f.service), first = state.snapshot();
  state.status(roots[1], 'idle'); state.status(roots[4], 'idle');
  const second = state.snapshot();
  assert.deepEqual(second.pets.map(p => p.id), ['s0', 's1', 's2', 's3', 's5', 's6']);
  assert.equal(second.pets.find(p => p.id === 's1').mode, 'idle');
  const additions = [f.add('running'), f.add('running')]; state.created();
  const third = state.snapshot();
  assert.equal(state.bindings[1], additions[0]); assert.equal(state.bindings[4], additions[1]);
  assert.equal(third.pets.find(p => p.id === 's4').epoch, first.pets[4].epoch + 2);
  assert.equal(third.pets.find(p => p.id === 's6').epoch, first.pets[6].epoch);
});
test('one mini per active nested child; idle resume retains exact identity and style', () => {
  const f = registry(), root = f.add(), child = f.add('running', root), nested = f.add('running', child);
  const state = new Activity(f.service), first = state.snapshot();
  assert.equal(first.activeSubagents, 2); assert.equal(first.activeJobs, 0);
  const minis = first.pets.filter(p => p.role === 'subagent');
  assert.deepEqual(minis.map(p => [p.id, p.parent, p.style, p.mode]), [['a0', 's0', 0, 'thinking'], ['a1', 's0', 0, 'thinking']]);
  state.status(child, 'idle'); assert.equal(state.snapshot().activeSubagents, 1);
  state.status(child, 'running');
  assert.deepEqual(state.snapshot().pets.find(p => p.id === 'a0'), minis[0]);
  f.remove(child); state.disposed(child);
  const replacement = f.add('running', root, child.id); state.created();
  const next = state.snapshot();
  assert.ok(!next.pets.some(p => p.id === 'a0')); assert.ok(next.pets.some(p => p.id === 'a2'));
  state.status(child, 'idle'); state.disposed(child);
  assert.equal(state.running.has(replacement), true); assert.equal(state.running.has(nested), true);
});
test('unknown orphan has a stable unparented mini but no invented root', () => {
  const f = registry(), orphan = f.add('running', { id: 'missing' });
  const state = new Activity(f.service), first = state.snapshot();
  assert.equal(first.activeChats, 0); assert.equal(first.activeSubagents, 1);
  const mini = first.pets.at(-1); assert.equal(mini.parent, null);
  state.status(orphan, 'idle'); state.snapshot(); state.status(orphan, 'running');
  assert.deepEqual(state.snapshot().pets.at(-1), mini);
});
test('owned jobs keep root/style anchors stable through idle and owner disposal', () => {
  const f = registry(), root = f.add('running'), child = f.add('running', root);
  const state = new Activity(f.service); state.snapshot();
  state.jobEvent('registered', job('private-job', child.id));
  const first = state.snapshot(), mini = first.pets.find(p => p.role === 'job');
  state.status(root, 'idle'); state.status(child, 'idle');
  assert.equal(state.snapshot().activeChats, 1); assert.equal(state.snapshot().activeSubagents, 0);
  f.remove(root); f.remove(child); state.disposed(root);
  const fresh = f.add('running', undefined, root.id); state.created();
  const later = state.snapshot();
  assert.equal(later.activeChats, 2); assert.deepEqual(later.pets.find(p => p.role === 'job'), mini);
  assert.equal(state.bindings[0], root); assert.equal(state.bindings[1], fresh);
  state.jobEvent('settled', job('private-job', child.id, 'completed'));
  assert.equal(state.snapshot().activeJobs, 0); assert.equal(state.snapshot().activeChats, 1);
});
test('unowned/unknown-owner jobs never fabricate a chat or migrate to a reused owner ID', () => {
  const f = registry(), state = new Activity(f.service);
  state.jobEvent('registered', job('unowned'));
  state.jobEvent('registered', job('unknown', 'not-live'));
  const first = state.snapshot(); assert.equal(first.activeJobs, 2); assert.equal(first.activeChats, 0);
  assert.ok(first.pets.filter(p => p.role === 'job').every(p => p.parent === null));
  f.add('idle', undefined, 'not-live'); state.created();
  assert.deepEqual(state.snapshot(), first);
});
test('job projections read metadata only; progress dedupes; stopping remains until any terminal', () => {
  for (const terminal of ['completed', 'failed', 'killed']) {
    const f = registry(), state = new Activity(f.service), view = job('private-job');
    assert.equal(state.jobEvent('registered', view), true);
    const first = state.snapshot();
    assert.equal(state.jobEvent('progress', job('private-job')), false);
    assert.equal(state.jobEvent('stopping', job('private-job', undefined, 'stopping')), true);
    assert.deepEqual(state.snapshot(), first);
    assert.equal(state.jobEvent('progress', job('private-job', undefined, terminal)), true);
    assert.equal(state.snapshot().activeJobs, 0);
    assert.equal(state.jobEvent('progress', view), false);
    assert.equal(state.snapshot().activeJobs, 0);
  }
});
test('late old job settlement/removal cannot affect a same-ID newer registration', () => {
  const f = registry(), state = new Activity(f.service);
  state.jobEvent('registered', job('same-id', undefined, 'running', 1));
  const before = state.snapshot().pets.at(-1);
  state.jobEvent('registered', job('same-id', undefined, 'running', 2));
  const replacement = state.snapshot(); assert.notEqual(replacement.pets.at(-1).id, before.id);
  for (const event of ['settled', 'removed', 'stopping', 'registered']) state.jobEvent(event, job('same-id', undefined, event === 'registered' ? 'running' : 'completed', 1));
  assert.deepEqual(state.snapshot(), replacement);
  state.jobEvent('removed', job('same-id', undefined, 'completed', 2));
  assert.equal(state.snapshot().activeJobs, 0);
});
test('cosmetic observer failure cannot suppress next or replace outcomes', async () => {
  const f = fixture(); f.env.activity.has = () => { throw new Error('cosmetic'); };
  let calls = 0;
  assert.equal(await observeInteraction({ agent: f.agent }, () => { calls++; return 'allowed-once'; }, f.env, f.clock), 'allowed-once');
  assert.equal(calls, 1);
});
