// TEST ONLY. Never imported by the Host plugin; no Harness registry interaction.
import { Activity } from './activity.js';
export function registry() {
  const entries = new Map(), calls = { list: 0, roots: 0, ownership: 0 };
  const service = {
    list() { calls.list++; return [...entries.keys()]; },
    roots() { calls.roots++; return [...entries].filter(([, owner]) => !owner).map(([agent]) => agent); },
    isOwnedBy(id, owner) { calls.ownership++; return [...entries].some(([agent, parent]) => agent.id === id && parent === owner); },
  };
  let serial = 0;
  const add = (status = 'idle', owner, id = `private-${++serial}`) => {
    const agent = { id, status };
    for (const key of ['session', 'messages', 'label', 'content']) Object.defineProperty(agent, key, { get() { throw new Error(`Forbidden agent read: ${key}`); } });
    entries.set(agent, owner); return agent;
  };
  return { service, entries, calls, add, remove: agent => entries.delete(agent) };
}
export function job(id, owner, status = 'running', startedAt = 1, kind = 'bash') {
  const view = { id, kind, status, owner, startedAt };
  for (const key of ['label', 'progress', 'detail', 'output', 'finishedAt', 'result']) Object.defineProperty(view, key, { enumerable: true, get() { throw new Error(`Forbidden job read: ${key}`); } });
  return view;
}
export function deferred() {
  let resolve, reject;
  const promise = new Promise((r, j) => { resolve = r; reject = j; });
  return { promise, resolve, reject };
}
export function scenario(count) {
  const f = registry(), roots = Array.from({ length: count }, () => f.add('running'));
  if (count) { const child = f.add('running', roots[0]); f.add('running', child); }
  const activity = new Activity(f.service);
  if (count) activity.jobEvent('registered', job('private-job', roots.at(-1).id));
  if (count >= 4) activity.jobEvent('registered', job('private-unowned'));
  return activity.snapshot();
}
export function nativeFixtures() {
  const f = registry(), root = f.add(), activity = new Activity(f.service);
  const startup = activity.snapshot();
  activity.jobEvent('registered', job('private-baseline', root.id));
  const baseline = activity.snapshot();
  activity.jobEvent('registered', job('private-immediate', undefined, 'running', 2));
  const immediate = activity.snapshot();
  activity.jobEvent('settled', job('private-baseline', root.id, 'completed'));
  activity.jobEvent('removed', job('private-immediate', undefined, 'completed', 2));
  return [startup, ...[0, 1, 4, 7].map(scenario), baseline, immediate, activity.snapshot()];
}
