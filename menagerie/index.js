import { Activity, observeInteraction } from './activity.js';
import { startBridge } from './bridge.js';

export const inject = ['agents', 'jobs', 'subprocess'];

export function apply(ctx) {
  if (process.platform !== 'darwin') return;
  return ctx.effect(() => attach(ctx));
}

// Dependency seams let tests exercise lifecycle without spawning native/runtime work.
export function attach(ctx, { createBridge = startBridge, clock } = {}) {
  let active = true, bridge, seeding = true, disposal;
  const activity = new Activity(ctx.agents);
  const cleanups = new Set(), listeners = [], touched = new Set();
  const publish = () => {
    if (active && bridge) { try { bridge.publish(activity.snapshot()); } catch {} }
  };
  const observe = (request, next) => observeInteraction(request, next,
    { activity, publish, active: () => active, cleanups }, clock);
  const update = operation => payload => {
    if (active) { try { operation(payload); publish(); } catch {} }
  };
  const detach = () => {
    active = false;
    for (const dispose of listeners.splice(0)) { try { dispose(); } catch {} }
    for (const cancel of [...cleanups]) cancel();
    activity.clear(); touched.clear();
  };
  try {
    // Subscribe BEFORE list(): events win over stale baseline projections,
    // including terminal/removal events that leave no active record to dedupe.
    listeners.push(ctx.jobs.events.subscribe({ owners: 'all' }, event => {
      if (!active || event.type === 'output') return;
      if (!['registered', 'progress', 'stopping', 'settled', 'removed'].includes(event.type)) return;
      try {
        if (seeding) touched.add(event.job.id);
        const type = seeding && (event.type === 'progress' || event.type === 'stopping') ? 'registered' : event.type;
        if (activity.jobEvent(type, event.job)) publish();
      } catch { /* Cosmetics cannot fail registry event delivery. */ }
    }));
    listeners.push(
      ctx.on('agent/created', update(() => activity.created())),
      ctx.on('agent/status', update(({ agent, status }) => activity.status(agent, status))),
      ctx.on('agent/disposed', update(({ agent }) => {
        activity.disposed(agent);
        for (const cancel of [...cleanups]) if (cancel.agent === agent) cancel();
      })),
      ctx.on('approval/request', observe, { prepend: true }),
      ctx.on('user-questions/request', observe, { prepend: true }),
    );
    const seen = new Set();
    const seed = views => {
      for (const view of views) {
        if (touched.has(view.id) || seen.has(view.id)) continue;
        seen.add(view.id);
        activity.jobEvent('registered', view);
      }
    };
    seed(ctx.jobs.list()); // omission sees unowned only
    for (const agent of activity.live) seed(ctx.jobs.list(agent.id));
    seeding = false; touched.clear();
    // Helper is a managed subprocess, NOT a registry job; never count it.
    bridge = createBridge(ctx.subprocess, activity.snapshot());
  } catch (error) {
    detach();
    throw error;
  }
  return () => {
    if (disposal) return disposal;
    detach();
    disposal = Promise.resolve().then(() => bridge.dispose());
    return disposal;
  };
}
