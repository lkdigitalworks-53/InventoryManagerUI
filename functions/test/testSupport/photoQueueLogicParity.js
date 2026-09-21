// Plain-Node mirror of qml/helper/PhotoQueueLogic.js (identical body, minus the
// ".pragma library" line and using module.exports in place of bare function declarations
// being globally visible). Keep these two in sync by hand -- same convention as
// StuckWrites.js / Skill 67.

const BACKOFF_MS = [2000, 8000, 30000, 120000, 600000]; // identical to OutboxStore._backoffMs -- do not fork
const ATTEMPT_CAP = 8;
const TERMINAL_STATUS = { 400: true, 413: true, 404: true, 409: true };
const BREAKER_TRIP_AFTER = 5;
const BREAKER_COOLDOWN_BASE_MS = 60000;
const BREAKER_COOLDOWN_MAX_MS = 600000;

function classifyError(status) {
  return TERMINAL_STATUS[status] ? 'terminal' : 'transient';
}

function nextBackoffMs(attempts) {
  const idx = Math.min(attempts - 1, BACKOFF_MS.length - 1);
  return BACKOFF_MS[Math.max(idx, 0)];
}

function reduceQueueItem(item, event) {
  if (event.type === 'sent' || event.type === 'discard') return null;
  if (event.type === 'retry') {
    return { ...item, state: 'enqueued', attempts: 0, nextAttemptAt: 0, lastError: null };
  }
  if (event.type === 'failed') {
    // A failure report only makes sense for an item that is actually in flight. A stale or
    // duplicate report against an item that already moved on (e.g. already 'failed', or reset
    // by a 'retry' in between) is ignored rather than double-counted -- keeps this reducer total
    // (safe for any caller mistake) instead of relying on the caller never misordering events.
    if (item.state !== 'uploading') return item;
    const attempts = item.attempts + 1;
    const kind = classifyError(event.status);
    if (kind === 'terminal' || attempts >= ATTEMPT_CAP) {
      return { ...item, state: 'failed', attempts, lastError: event.status };
    }
    return {
      ...item, state: 'retrying', attempts, lastError: event.status,
      nextAttemptAt: Date.now() + nextBackoffMs(attempts),
    };
  }
  return item;
}

// tripCount escalates the cooldown across repeated trips that happen without a genuine
// 'success' event in between (a successful call is the only thing that resets it). This is
// deliberately a separate counter from consecutiveFailures/status: a caller can reset those two
// (e.g. after a cooldown window elapses and it starts allowing attempts again) without that
// alone re-earning the 60s base cooldown -- only an actual successful upload does that.
function breakerReducer(state, event) {
  const tripCount = state.tripCount || 0;
  if (event.type === 'success') {
    return { ...state, status: 'closed', consecutiveFailures: 0, tripCount: 0 };
  }
  const failures = state.consecutiveFailures + 1;
  if (failures >= BREAKER_TRIP_AFTER) {
    const cooldownMs = tripCount === 0
      ? BREAKER_COOLDOWN_BASE_MS
      : Math.min(state.cooldownMs * 2, BREAKER_COOLDOWN_MAX_MS);
    return {
      status: 'open', consecutiveFailures: failures,
      cooldownUntil: Date.now() + cooldownMs, cooldownMs, tripCount: tripCount + 1,
    };
  }
  return { ...state, consecutiveFailures: failures };
}

function isBreakerOpen(state, now) {
  const t = typeof now === 'number' ? now : Date.now();
  return state.status === 'open' && t < state.cooldownUntil;
}

module.exports = { classifyError, nextBackoffMs, reduceQueueItem, breakerReducer, isBreakerOpen };
