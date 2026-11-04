// Fresh v3 module graph: no imports from cached root/colony Host generations.
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const ROOT = fileURLToPath(new URL('../', import.meta.url));
export const EXECUTABLE = fileURLToPath(new URL('../app/DSH Window Cat.app/Contents/MacOS/DSHWindowCat', import.meta.url));
export const STATUS_PATH = pathToFileURL(join(tmpdir(), 'dsh-pets', String(process.pid), 'status.json'));
export const MAX_LINE_BYTES = 1024 * 1024; // includes the newline, in both directions
export const MAX_DIAGNOSTIC_BYTES = 8192;

function bounded(event) {
  return Buffer.byteLength(JSON.stringify(event)) <= MAX_DIAGNOSTIC_BYTES ? event
    : { type: String(event.type).slice(0, 80), truncated: true };
}

export function startBridge(subprocess, initial, { writeStatus } = {}) {
  let active = true, alive = true, inputOpen = true, blocked = false, pending, lastSent, lastPublished;
  let buffer = '', bufferBytes = 0, dropping = false, diagnosticTimer, finished = false;
  let writes, pendingStatus;
  const status = { hostPid: process.pid, phase: 'starting', helper: null, activity: null, events: [] };
  const directory = new URL('.', STATUS_PATH);
  const persist = () => {
    // At most one in-flight write and one latest pending snapshot even on slow disks.
    pendingStatus = JSON.stringify({ ...status, updatedAt: new Date().toISOString() }) + '\n';
    if (!writes) writes = Promise.resolve().then(async () => {
      while (pendingStatus !== undefined) {
        const text = pendingStatus; pendingStatus = undefined;
        try {
          if (writeStatus) await writeStatus(text);
          else {
            await mkdir(directory, { recursive: true, mode: 0o700 });
            await writeFile(STATUS_PATH, text, { mode: 0o600 });
          }
        } catch (error) { console.warn('[native-window-cat] Diagnostic write failed:', String(error.code).slice(0, 80)); }
      }
      // Clear synchronously with the empty-queue observation, not in a later
      // finally microtask where a new persist() could otherwise lose its frame.
      writes = undefined;
    });
    return writes;
  };
  const diagnose = event => {
    if (finished) return;
    status.events.push({ ...bounded(event), at: new Date().toISOString() });
    status.events = status.events.slice(-24);
    if (!diagnosticTimer) {
      diagnosticTimer = setTimeout(() => { diagnosticTimer = undefined; void persist(); }, 100);
      diagnosticTimer.unref?.();
    }
  };
  let handle;
  try {
    handle = subprocess.spawn({
      argv: [EXECUTABLE], cwd: ROOT, graceMs: 1500,
      stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' },
    });
  } catch (error) {
    alive = false; status.phase = 'spawn-failed';
    diagnose({ type: 'spawn-error', message: String(error.message).slice(0, 1000) });
    return { publish() {}, async dispose() { clearTimeout(diagnosticTimer); finished = true; await persist(); } };
  }
  const inputError = error => { inputOpen = false; diagnose({ type: 'pipe-error', code: String(error.code ?? 'unknown').slice(0, 80) }); };
  const inputClosed = () => { inputOpen = false; };
  handle.stdin?.on('error', inputError);
  handle.stdin?.on('close', inputClosed);
  function flush() {
    if (!active || !alive || !inputOpen || blocked || !pending || !handle.stdin || handle.stdin.destroyed) return;
    const frame = pending;
    pending = undefined;
    if (frame === lastSent) return;
    try { blocked = !handle.stdin.write(frame); lastSent = frame; }
    catch (error) { inputError(error); }
  }
  const onDrain = () => { blocked = false; flush(); };
  handle.stdin?.on('drain', onDrain);
  function publish(frame) {
    if (!active) return;
    const line = JSON.stringify(frame) + '\n';
    if (Buffer.byteLength(line) > MAX_LINE_BYTES) {
      diagnose({ type: 'activity-too-large', maxBytes: MAX_LINE_BYTES });
      return; // never truncate roles or publish contradictory counts
    }
    if (line === lastPublished) return;
    lastPublished = line;
    status.activity = frame;
    pending = line;
    flush();
    diagnose({ type: 'activity', version: frame.version, activeChats: frame.activeChats,
      waitingChats: frame.waitingChats, activeSubagents: frame.activeSubagents, activeJobs: frame.activeJobs,
      pets: frame.pets.length });
  }
  const onData = chunk => {
    // Bound bytes, not UTF-16 code units. Oversized lines recover at the next LF.
    for (const segment of String(chunk).split(/(?<=\n)/)) {
      if (dropping) { if (segment.endsWith('\n')) dropping = false; continue; }
      const bytes = Buffer.byteLength(segment);
      if (bufferBytes + bytes > MAX_LINE_BYTES) {
        buffer = ''; bufferBytes = 0; dropping = !segment.endsWith('\n'); continue;
      }
      buffer += segment; bufferBytes += bytes;
      if (!buffer.endsWith('\n')) continue;
      const line = buffer.trim(); buffer = ''; bufferBytes = 0;
      try {
        const event = JSON.parse(line);
        if (!event || typeof event.type !== 'string') continue;
        const safe = bounded(event);
        if (event.type === 'ready') { status.phase = 'running'; status.helper = safe; }
        if (event.type === 'accessibility') status.accessibility = safe;
        if (event.type === 'tracking') status.tracking = safe;
        diagnose(safe);
      } catch { /* Non-JSON diagnostics never affect the Host. */ }
    }
  };
  const onStderr = chunk => diagnose({ type: 'stderr', text: String(chunk).slice(-1200) });
  const outputError = error => diagnose({ type: 'output-error', code: String(error.code ?? 'unknown').slice(0, 80) });
  handle.stdout?.setEncoding('utf8');
  handle.stdout?.on('data', onData);
  handle.stdout?.on('error', outputError);
  handle.stderr?.setEncoding('utf8');
  handle.stderr?.on('data', onStderr);
  handle.stderr?.on('error', outputError);
  const completed = handle.done.then(outcome => {
    alive = false; status.phase = active ? 'exited' : 'stopped'; diagnose({ type: 'exit', ...outcome });
  }, error => {
    alive = false; status.phase = 'failed'; diagnose({ type: 'process-error', message: String(error.message).slice(0, 1000) });
  });
  publish(initial);
  let disposal;
  return {
    publish,
    dispose() {
      if (disposal) return disposal;
      active = false; pending = undefined;
      handle.stdin?.off('drain', onDrain);
      handle.stdin?.off('close', inputClosed);
      // EOF then the SAME managed provider's escalation; no PID searches/open(1).
      try { handle.stdin?.end(); } catch { /* Pipe may already be closed. */ }
      if (alive) handle.terminate();
      disposal = (async () => {
        await completed;
        handle.stdout?.off('data', onData);
        handle.stderr?.off('data', onStderr);
        // Retain error sinks for queued post-completion errors (no Agent data).
        clearTimeout(diagnosticTimer);
        diagnosticTimer = undefined;
        finished = true; buffer = ''; bufferBytes = 0;
        status.phase = 'stopped';
        await persist();
      })();
      return disposal;
    },
  };
}
