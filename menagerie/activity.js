// Process-local exact Agent objects; only anonymous identities cross the wire.
export const CAT_COUNT = 3;

// Never spread JobView: label/progress/detail/output are intentionally unread.
export function projectJob(job) {
  return { id: job.id, kind: job.kind, status: job.status, owner: job.owner, startedAt: job.startedAt };
}
const busyJob = job => job.status === 'running' || job.status === 'stopping';
const sameJob = (a, b) => a.id === b.id && a.kind === b.kind && a.owner === b.owner && a.startedAt === b.startedAt;

export class Activity {
  constructor(agents) {
    this.agents = agents;
    this.live = new Set();
    this.roots = new Set();
    this.liveById = new Map();
    this.rootOf = new Map();
    this.running = new Set();
    this.pending = new Map();
    this.bindings = Array(CAT_COUNT).fill(undefined);
    this.epochs = Array(CAT_COUNT).fill(0);
    this.minis = new Map();
    this.jobs = new Map();
    this.agentSerial = 0;
    this.jobSerial = 0;
    this.ownStyle = 0;
    this.rebuild();
  }

  // isOwnedBy is DIRECT runtime ownership. Cache topology only on created/disposed.
  rebuild(excluded) {
    const agents = this.agents.list().filter(agent => agent !== excluded);
    const live = new Set(agents);
    const roots = new Set(this.agents.roots().filter(agent => live.has(agent)));
    const previous = this.rootOf;
    const owners = new Map();
    for (const agent of agents) {
      if (roots.has(agent)) continue;
      const owner = agents.find(candidate => candidate !== agent && this.agents.isOwnedBy(agent.id, candidate));
      if (owner) owners.set(agent, owner);
    }
    const resolved = new Map(), resolving = new Set();
    const resolve = agent => {
      if (resolved.has(agent)) return resolved.get(agent);
      if (resolving.has(agent)) return undefined;
      resolving.add(agent);
      const owner = owners.get(agent);
      // Retain an orphan's EXACT prior root, never a new object reusing its ID.
      const root = roots.has(agent) ? agent : (owner ? resolve(owner) : undefined) ?? previous.get(agent);
      resolving.delete(agent);
      resolved.set(agent, root);
      return root;
    };
    for (const agent of agents) {
      resolve(agent);
      if (!this.live.has(agent) && agent.status === 'running') this.running.add(agent);
    }
    for (const agent of this.running) if (!live.has(agent)) this.running.delete(agent);
    for (const [token, agent] of this.pending) if (!live.has(agent)) this.pending.delete(token);
    for (const agent of this.minis.keys()) if (!live.has(agent)) this.minis.delete(agent);
    this.live = live;
    this.roots = roots;
    this.liveById = new Map(agents.map(agent => [agent.id, agent]));
    this.rootOf = resolved;
    // A captured owner may gain a known root, but can NEVER be replaced by ID.
    for (const job of this.jobs.values()) {
      if (job.ownerAgent && live.has(job.ownerAgent)) job.root = resolved.get(job.ownerAgent) ?? job.root;
    }
  }

  created() { this.rebuild(); }
  status(agent, status) {
    if (!this.live.has(agent)) return;
    if (status === 'running') this.running.add(agent);
    else if (status === 'idle') this.running.delete(agent);
  }
  disposed(agent) { this.rebuild(agent); }
  has(agent) { return this.live.has(agent) && Boolean(this.rootOf.get(agent)); }
  begin(token, agent) {
    if (!this.has(agent)) return false;
    this.pending.set(token, agent);
    return true;
  }
  end(token) { return this.pending.delete(token); }

  // Views are fresh projections, not stable objects. Registry identity is the
  // (id, startedAt, kind, owner) tuple; late events cannot settle a replacement.
  jobEvent(type, view) {
    const job = projectJob(view), old = this.jobs.get(job.id);
    if (old && !sameJob(old, job)) {
      if (type !== 'registered' || job.startedAt <= old.startedAt) return false;
    }
    if (type === 'removed' || type === 'settled' || !busyJob(job)) {
      if (!old || !sameJob(old, job)) return false;
      this.jobs.delete(job.id);
      return true;
    }
    if (old && sameJob(old, job)) {
      if (old.status === job.status) return false;
      old.status = job.status;
      return true;
    }
    // Progress is not registration, and cannot resurrect a terminal record.
    if (type !== 'registered') return false;
    const ownerAgent = this.liveById.get(job.owner);
    this.jobs.set(job.id, {
      ...job, ownerAgent, root: this.rootOf.get(ownerAgent),
      anonymous: `j${this.jobSerial++}`, style: this.ownStyle++,
    });
    return true;
  }

  clear() {
    this.running.clear(); this.pending.clear(); this.live.clear();
    this.roots.clear(); this.liveById.clear(); this.rootOf.clear();
    this.minis.clear(); this.jobs.clear(); this.bindings.fill(undefined);
  }

  snapshot() {
    const active = new Set(), waiting = new Set();
    for (const agent of this.running) {
      const root = this.rootOf.get(agent);
      if (root) active.add(root);
    }
    for (const agent of this.pending.values()) {
      const root = this.rootOf.get(agent);
      if (root) { active.add(root); waiting.add(root); }
    }
    for (const job of this.jobs.values()) if (job.root) active.add(job.root);
    // Keep every active binding. Release holes without compacting or rotating.
    for (let i = 0; i < this.bindings.length; i++) {
      if (this.bindings[i] && !active.has(this.bindings[i])) {
        this.bindings[i] = undefined;
        this.epochs[i]++;
      }
    }
    const slots = new Map();
    this.bindings.forEach((root, i) => { if (root) slots.set(root, i); });
    for (const root of active) {
      if (slots.has(root)) continue;
      let slot = this.bindings.indexOf(undefined);
      if (slot < 0) slot = this.bindings.length;
      this.bindings[slot] = root;
      this.epochs[slot] = (this.epochs[slot] ?? 0) + 1;
      slots.set(root, slot);
    }
    const pets = [];
    this.bindings.forEach((root, i) => {
      if (i >= CAT_COUNT && !root) return;
      pets.push({ id: `s${i}`, role: 'session', parent: null, style: i,
        mode: !root ? 'idle' : waiting.has(root) ? 'awaiting' : 'thinking', epoch: this.epochs[i] });
    });
    const mini = (id, role, root, ownStyle) => {
      const style = slots.get(root);
      pets.push({ id, role, parent: style === undefined ? null : `s${style}`,
        style: style ?? ownStyle, mode: 'thinking', epoch: 0 });
    };
    let activeSubagents = 0;
    for (const agent of this.running) {
      if (this.roots.has(agent)) continue;
      let identity = this.minis.get(agent);
      if (!identity) {
        identity = { id: `a${this.agentSerial++}`, style: this.ownStyle++ };
        this.minis.set(agent, identity);
      }
      mini(identity.id, 'subagent', this.rootOf.get(agent), identity.style);
      activeSubagents++;
    }
    for (const job of this.jobs.values()) mini(job.anonymous, 'job', job.root, job.style);
    return { version: 3, activeChats: active.size, waitingChats: waiting.size,
      activeSubagents, activeJobs: this.jobs.size, pets };
  }
}

// Prepending waterfall observer: next() exactly once, no answering, racing,
// authorization changes, or manufactured outcomes. Visible attention waits 200ms.
export function observeInteraction(request, next, { activity, publish, active, cleanups }, clock = { setTimeout, clearTimeout }) {
  const token = Symbol('interaction');
  let timer, ended = false;
  const cancel = () => {
    if (ended) return;
    ended = true;
    try { if (timer !== undefined) clock.clearTimeout(timer); } catch {}
    try { request.signal?.removeEventListener('abort', cancel); } catch {}
    cleanups.delete(cancel);
    try { if (activity.end(token)) publish(); } catch {}
  };
  cancel.agent = request.agent;
  try {
    if (active() && !request.signal?.aborted && activity.has(request.agent)) {
      cleanups.add(cancel);
      timer = clock.setTimeout(() => {
        try { if (!ended && active() && activity.begin(token, request.agent)) publish(); } catch {}
      }, 200);
      timer?.unref?.();
      request.signal?.addEventListener('abort', cancel, { once: true });
    }
  } catch { cancel(); }
  try { return Promise.resolve(next()).finally(cancel); }
  catch (error) { cancel(); throw error; }
}
