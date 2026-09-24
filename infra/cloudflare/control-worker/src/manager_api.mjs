export const MANAGER_ROTATE_SCHEMA = "mish.control.rotate/v1";
export const MANAGER_ROTATE_WAIT_TIMEOUT_MS = 180_000;

const RESULTS = new Set(["CHANGED", "UNCHANGED", "FAILED", "REJECTED", "UNKNOWN"]);
const REASONS = new Set([
  "NONE",
  "UNAUTHORIZED",
  "METHOD_NOT_ALLOWED",
  "INVALID_REQUEST",
  "DEVICE_OFFLINE",
  "BUSY",
  "PRODUCT_FAILED",
  "PRODUCT_REJECTED",
  "TIMEOUT",
  "INTERNAL_ERROR",
]);

export function newManagerRequestId() {
  return `mgr_${crypto.randomUUID().replaceAll("-", "")}`;
}

export function managerRotatePayload({
  requestId = null,
  result,
  reason,
  operationId = null,
  deviceOnline = null,
  dispatched = false,
  startedAtMs,
  completedAtMs = Date.now(),
}) {
  if (!RESULTS.has(result)) throw new Error("invalid manager result");
  if (!REASONS.has(reason)) throw new Error("invalid manager reason");
  if (requestId !== null && (typeof requestId !== "string" || requestId.length === 0)) {
    throw new Error("invalid manager request id");
  }
  if (operationId !== null && (!Number.isSafeInteger(operationId) || operationId <= 0)) {
    throw new Error("invalid manager operation id");
  }
  if (deviceOnline !== null && typeof deviceOnline !== "boolean") {
    throw new Error("invalid manager device-online value");
  }
  if (dispatched !== null && typeof dispatched !== "boolean") {
    throw new Error("invalid manager dispatched value");
  }
  if (!Number.isSafeInteger(startedAtMs) || !Number.isSafeInteger(completedAtMs) ||
      completedAtMs < startedAtMs) {
    throw new Error("invalid manager timing");
  }

  const changed = result === "CHANGED" ? true : result === "UNCHANGED" ? false : null;
  const terminal = result !== "UNKNOWN";
  const retryable = dispatched === false &&
    (reason === "DEVICE_OFFLINE" || reason === "BUSY");

  return {
    schema: MANAGER_ROTATE_SCHEMA,
    request_id: requestId,
    terminal,
    result,
    reason,
    operation_id: operationId,
    changed,
    device_online: deviceOnline,
    dispatched,
    retryable,
    timing: {
      started_at_ms: startedAtMs,
      completed_at_ms: completedAtMs,
      duration_ms: completedAtMs - startedAtMs,
    },
  };
}

export function managerJson(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

export function terminalOperationPayload(operation, deviceOnline = true) {
  if (!operation || operation.status !== "TERMINAL") {
    throw new Error("terminal operation required");
  }
  const mapping = {
    CHANGED: ["CHANGED", "NONE"],
    UNCHANGED: ["UNCHANGED", "NONE"],
    FAILED: ["FAILED", "PRODUCT_FAILED"],
    REJECTED: ["REJECTED", "PRODUCT_REJECTED"],
    UNKNOWN: ["UNKNOWN", "TIMEOUT"],
  };
  const mapped = mapping[operation.result];
  if (!mapped) throw new Error("unsupported terminal operation result");

  return managerRotatePayload({
    requestId: operation.request_id,
    result: mapped[0],
    reason: mapped[1],
    operationId: operation.operation_id || null,
    deviceOnline,
    dispatched: true,
    startedAtMs: operation.created_at_ms,
    completedAtMs: operation.completed_at_ms,
  });
}
