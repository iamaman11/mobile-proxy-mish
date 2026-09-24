import {
  MANAGER_ROTATE_WAIT_TIMEOUT_MS,
  managerJson,
  managerRotatePayload,
  newManagerRequestId,
  terminalOperationPayload,
} from "./manager_api.mjs";
import {
  MAX_RECENT_OPERATIONS,
  canonicalAuthPayload,
  challengeMessage,
  deviceIdFromSpkiB64,
  isDeviceId,
  isFreshAuthChallenge,
  managerAuthorized,
  parseDeviceMessage,
  parseEnrollmentBody,
  parseManagerRotateBody,
  randomNonce,
  readBoundedJson,
  readyMessage,
  resultAckMessage,
  rotateMessage,
  verifyDeviceSignature,
} from "./protocol.mjs";

const DEVICE_CONNECT = "/v1/device/connect";
const MANAGER_ROTATE = "/v1/rotate";
const PRIMARY_DEVICE_OBJECT = "primary";

// PRODUCT owns mutation timing. Its canonical rotation safety deadline is 90 s.
// CONTROL adds margin for terminal delivery, and fences an unaccepted dispatch before
// ever releasing BUSY so an old in-flight command cannot overlap a newer mutation.
const PRODUCT_ROTATION_SAFETY_MS = 90_000;
const CONTROL_DELIVERY_MARGIN_MS = 30_000;
const ACCEPTED_RESULT_LEASE_MS = PRODUCT_ROTATION_SAFETY_MS + CONTROL_DELIVERY_MARGIN_MS;
const INITIAL_DELIVERY_ACK_MS = 10_000;
const RECOVERY_DELIVERY_ACK_MS = 15_000;
const FENCED_DRAIN_MS = PRODUCT_ROTATION_SAFETY_MS + CONTROL_DELIVERY_MARGIN_MS;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === DEVICE_CONNECT) {
      const deviceId = url.searchParams.get("device_id");
      if (!isDeviceId(deviceId) || url.searchParams.size !== 1 ||
          request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "INVALID_DEVICE_REQUEST" }, 400);
      }
      return primaryDeviceStub(env).fetch(
        new Request(`https://control.internal/device/connect?device_id=${deviceId}`, request),
      );
    }

    if (url.pathname === MANAGER_ROTATE) {
      const startedAtMs = Date.now();
      if (request.method !== "POST") {
        return managerJson(managerRotatePayload({
          result: "REJECTED",
          reason: "METHOD_NOT_ALLOWED",
          dispatched: false,
          startedAtMs,
        }), 405);
      }
      if (!(await managerAuthorized(request, env.MISH_MANAGER_TOKEN))) {
        return managerJson(managerRotatePayload({
          result: "REJECTED",
          reason: "UNAUTHORIZED",
          dispatched: false,
          startedAtMs,
        }), 401);
      }

      const body = await request.text();
      if (body.length !== 0) {
        return managerJson(managerRotatePayload({
          result: "REJECTED",
          reason: "INVALID_REQUEST",
          dispatched: false,
          startedAtMs,
        }), 400);
      }

      const requestId = newManagerRequestId();
      try {
        return await primaryDeviceStub(env).fetch(new Request(
          "https://control.internal/manager/rotate-and-wait",
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ request_id: requestId }),
          },
        ));
      } catch {
        return managerJson(managerRotatePayload({
          requestId,
          result: "UNKNOWN",
          reason: "INTERNAL_ERROR",
          deviceOnline: null,
          dispatched: null,
          startedAtMs,
        }), 502);
      }
    }

    const enrollmentMatch = url.pathname.match(/^\/v1\/devices\/([0-9a-f]{64})$/u);
    if (!enrollmentMatch) return json({ error: "NOT_FOUND" }, 404);
    if (!(await managerAuthorized(request, env.MISH_MANAGER_TOKEN))) {
      return json({ error: "UNAUTHORIZED" }, 401);
    }
    if (request.method !== "PUT") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

    const deviceId = enrollmentMatch[1];
    let enrollment;
    try {
      enrollment = parseEnrollmentBody(await readBoundedJson(request));
    } catch {
      return json({ error: "INVALID_ENROLLMENT" }, 400);
    }
    if ((await deviceIdFromSpkiB64(enrollment.public_key_spki_b64)) !== deviceId) {
      return json({ error: "DEVICE_ID_PUBLIC_KEY_MISMATCH" }, 400);
    }
    return primaryDeviceStub(env).fetch(new Request(
      `https://control.internal/manager/enroll?device_id=${deviceId}`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(enrollment),
      },
    ));
  },
};

export class DeviceControl {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.waiters = new Map();
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/device/connect") return this.connectDevice(request);
    if (url.pathname === "/manager/enroll" && request.method === "PUT") {
      return this.enroll(request, url);
    }
    if (url.pathname === "/manager/rotate-and-wait" && request.method === "POST") {
      return this.rotateAndWait(request);
    }
    return json({ error: "NOT_FOUND" }, 404);
  }

  async enroll(request, url) {
    const deviceId = url.searchParams.get("device_id");
    if (!isDeviceId(deviceId) || url.searchParams.size !== 1) {
      return json({ error: "INVALID_DEVICE_ID" }, 400);
    }
    const body = parseEnrollmentBody(await readBoundedJson(request));
    if ((await deviceIdFromSpkiB64(body.public_key_spki_b64)) !== deviceId) {
      return json({ error: "DEVICE_ID_PUBLIC_KEY_MISMATCH" }, 400);
    }

    const current = await this.ctx.storage.get("device_identity");
    if (current &&
        (current.device_id !== deviceId ||
         current.public_key_spki_b64 !== body.public_key_spki_b64)) {
      return json({ error: "IDENTITY_ALREADY_BOUND" }, 409);
    }

    await this.ctx.storage.put("device_identity", {
      device_id: deviceId,
      public_key_spki_b64: body.public_key_spki_b64,
    });
    return json({ enrolled: true }, 200);
  }

  async connectDevice(request) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "WEBSOCKET_REQUIRED" }, 426);
    }
    const identity = await this.ctx.storage.get("device_identity");
    if (!identity) return json({ error: "DEVICE_NOT_ENROLLED" }, 404);

    const url = new URL(request.url);
    const deviceId = url.searchParams.get("device_id");
    if (!isDeviceId(deviceId) || deviceId !== identity.device_id) {
      return json({ error: "INVALID_DEVICE_ID" }, 400);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const challenge = randomNonce();
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({
      kind: "device",
      authenticated: false,
      device_id: deviceId,
      challenge,
      challenge_issued_at_ms: Date.now(),
    });
    server.send(challengeMessage(challenge));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message !== "string") {
      ws.close(1003, "text required");
      return;
    }

    const attachment = ws.deserializeAttachment();
    if (!attachment || attachment.kind !== "device" || !isDeviceId(attachment.device_id)) {
      ws.close(1008, "invalid session");
      return;
    }

    let parsed;
    try {
      parsed = parseDeviceMessage(message);
    } catch {
      ws.close(1008, "invalid protocol");
      return;
    }

    if (!attachment.authenticated) {
      if (parsed.type !== "AUTH" || parsed.device_id !== attachment.device_id) {
        ws.close(1008, "authentication required");
        return;
      }
      const identity = await this.ctx.storage.get("device_identity");
      if (!identity || identity.device_id !== attachment.device_id || !attachment.challenge) {
        ws.close(1008, "identity unavailable");
        return;
      }
      if (!isFreshAuthChallenge(attachment.challenge_issued_at_ms)) {
        ws.close(1008, "authentication expired");
        return;
      }
      const valid = await verifyDeviceSignature(
        identity.public_key_spki_b64,
        parsed.signature,
        canonicalAuthPayload(attachment.device_id, attachment.challenge),
      ).catch(() => false);
      if (!valid) {
        ws.close(1008, "authentication failed");
        return;
      }

      for (const existing of this.ctx.getWebSockets()) {
        if (existing === ws) continue;
        const other = existing.deserializeAttachment();
        if (other?.authenticated === true) {
          existing.serializeAttachment({ ...other, authenticated: false });
          existing.close(1000, "replaced");
        }
      }
      ws.serializeAttachment({
        kind: "device",
        authenticated: true,
        device_id: attachment.device_id,
      });

      // A reconnect is also a recovery boundary for legacy/stale broker state. Do not close
      // the newly authenticated socket while fencing: the previously authenticated socket
      // has already been replaced above.
      await this.reconcileActiveOperation(Date.now(), { fenceSockets: false });
      ws.send(readyMessage());

      const active = await this.ctx.storage.get("active_operation");
      if (active?.status === "DISPATCHED") {
        ws.send(rotateMessage(active.request_id));
      }
      return;
    }

    if (parsed.type === "ACCEPTED") {
      const active = await this.ctx.storage.get("active_operation");
      if (!active || active.request_id !== parsed.request_id) {
        const recent = (await this.ctx.storage.get("recent_operations")) || [];
        const known = recent.find((item) => item.request_id === parsed.request_id);
        if (known?.operation_id === parsed.operation_id) return;
        ws.close(1008, "unexpected acceptance");
        return;
      }
      if (active.operation_id && active.operation_id !== parsed.operation_id) {
        ws.close(1008, "operation id changed");
        return;
      }

      active.operation_id = parsed.operation_id;
      if (active.status === "DISPATCHED") {
        active.status = "ACCEPTED";
        active.accepted_at_ms = Date.now();
        active.delivery_deadline_ms = null;
        await this.ctx.storage.put("active_operation", active);
        await this.ctx.storage.setAlarm(active.accepted_at_ms + ACCEPTED_RESULT_LEASE_MS);
        this.resolveWaiters(parsed.request_id, active);
        return;
      }
      if (active.status === "ACCEPTED") {
        // Duplicate ACCEPTED is idempotent and must never extend the lease.
        await this.ctx.storage.put("active_operation", active);
        this.resolveWaiters(parsed.request_id, active);
        return;
      }
      if (active.status === "FENCED") {
        // The command may have crossed the wire just before fencing. Preserve its operation id
        // but never reactivate/redeliver it; the existing drain deadline remains authoritative.
        await this.ctx.storage.put("active_operation", active);
        return;
      }

      ws.close(1008, "invalid active operation state");
      return;
    }

    if (parsed.type === "RESULT") {
      await this.acceptResult(ws, parsed);
      return;
    }

    ws.close(1008, "unsupported device message");
  }

  async webSocketClose() {
    // compatibility_date >= 2026-04-07 auto-replies to Close frames.
  }

  async webSocketError() {
    // The client owns bounded reconnect. No server-side retry/queue is created here.
  }

  async rotateAndWait(request) {
    const command = parseManagerRotateBody(await readBoundedJson(request));
    const dispatch = await this.dispatchRotation(command.request_id);

    if (dispatch.kind === "TERMINAL") {
      return this.operationResponse(dispatch.operation);
    }
    if (dispatch.kind === "BUSY") {
      return managerJson(managerRotatePayload({
        requestId: command.request_id,
        result: "REJECTED",
        reason: "BUSY",
        operationId: null,
        deviceOnline: this.authenticatedSocket() !== null,
        dispatched: false,
        startedAtMs: Date.now(),
      }), 409);
    }
    if (dispatch.kind === "DEVICE_OFFLINE") {
      return managerJson(managerRotatePayload({
        requestId: command.request_id,
        result: "REJECTED",
        reason: "DEVICE_OFFLINE",
        operationId: null,
        deviceOnline: false,
        dispatched: false,
        startedAtMs: Date.now(),
      }), 409);
    }

    return this.waitForTerminal(command.request_id, dispatch.operation);
  }

  async dispatchRotation(requestId) {
    await this.reconcileActiveOperation(Date.now(), { fenceSockets: true });

    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const known = recent.find((item) => item.request_id === requestId);
    if (known) return { kind: "TERMINAL", operation: known };

    const active = await this.ctx.storage.get("active_operation");
    if (active) {
      if (active.request_id === requestId) {
        return { kind: "ACTIVE_SAME", operation: active };
      }
      return { kind: "BUSY", operation: active };
    }

    const socket = this.authenticatedSocket();
    if (!socket) return { kind: "DEVICE_OFFLINE" };

    const operation = {
      request_id: requestId,
      status: "DISPATCHED",
      operation_id: null,
      result: null,
      created_at_ms: Date.now(),
      accepted_at_ms: null,
      delivery_recovery_count: 0,
      delivery_deadline_ms: Date.now() + INITIAL_DELIVERY_ACK_MS,
      fenced_at_ms: null,
      release_at_ms: null,
      completed_at_ms: null,
    };
    try {
      await this.ctx.storage.put("active_operation", operation);
      await this.ctx.storage.setAlarm(operation.delivery_deadline_ms);
    } catch (error) {
      await this.ctx.storage.delete("active_operation").catch(() => {});
      await this.ctx.storage.deleteAlarm().catch(() => {});
      throw error;
    }

    try {
      socket.send(rotateMessage(requestId));
    } catch {
      await this.ctx.storage.delete("active_operation");
      await this.ctx.storage.deleteAlarm();
      return { kind: "DEVICE_OFFLINE" };
    }
    return { kind: "DISPATCHED", operation };
  }

  async waitForTerminal(requestId, operation) {
    const managerDeadlineMs = operation.created_at_ms + MANAGER_ROTATE_WAIT_TIMEOUT_MS;

    // socket.send() is not PRODUCT delivery proof. Give the current authenticated session
    // one short chance to return ACCEPTED, then force exactly one reconnect/redelivery of the
    // same request_id. PRODUCT idempotency makes that recovery safe if the first frame crossed
    // the wire but its ACCEPTED was lost.
    for (const deliveryWindowMs of [INITIAL_DELIVERY_ACK_MS, RECOVERY_DELIVERY_ACK_MS]) {
      const immediate = await this.currentOperationState(requestId);
      if (immediate.terminal) return this.operationResponse(immediate.terminal);
      if (immediate.active?.status === "ACCEPTED") break;
      if (!immediate.active || immediate.active.status === "FENCED") {
        return this.managerTimeoutResponse(requestId, operation);
      }

      const remainingMs = managerDeadlineMs - Date.now();
      if (remainingMs <= 0) return this.managerTimeoutResponse(requestId, operation);
      await this.waitForStateChange(
        requestId,
        immediate.active.status,
        Math.min(deliveryWindowMs, remainingMs),
      );

      const observed = await this.currentOperationState(requestId);
      if (observed.terminal) return this.operationResponse(observed.terminal);
      if (observed.active?.status === "ACCEPTED") break;
      if (!observed.active || observed.active.status === "FENCED") {
        return this.managerTimeoutResponse(requestId, operation);
      }

      await this.reconcileActiveOperation(Date.now(), { fenceSockets: true });
      const reconciled = await this.currentOperationState(requestId);
      if (reconciled.terminal) return this.operationResponse(reconciled.terminal);
      if (reconciled.active?.status === "ACCEPTED") break;
      if (!reconciled.active || reconciled.active.status === "FENCED") {
        return this.managerTimeoutResponse(requestId, operation);
      }
    }

    // ACCEPTED is the authoritative device-delivery boundary. Wait only inside the short
    // manager HTTP budget. If PRODUCT needs longer, its Durable Object correlation continues
    // under the existing 120 s accepted-result alarm; the manager gets typed UNKNOWN instead
    // of holding one DO request long enough to risk runtime eviction.
    while (Date.now() < managerDeadlineMs) {
      const current = await this.currentOperationState(requestId);
      if (current.terminal) return this.operationResponse(current.terminal);
      if (!current.active || current.active.status !== "ACCEPTED") {
        return this.managerTimeoutResponse(requestId, operation);
      }
      await this.waitForStateChange(
        requestId,
        "ACCEPTED",
        managerDeadlineMs - Date.now(),
      );
    }

    const final = await this.currentOperationState(requestId);
    if (final.terminal) return this.operationResponse(final.terminal);
    return this.managerTimeoutResponse(requestId, operation);
  }

  async waitForStateChange(requestId, expectedStatus, timeoutMs) {
    if (timeoutMs <= 0) return;

    let resolveChange;
    const changePromise = new Promise((resolve) => {
      resolveChange = resolve;
      let waiters = this.waiters.get(requestId);
      if (!waiters) {
        waiters = new Set();
        this.waiters.set(requestId, waiters);
      }
      waiters.add(resolve);
    });

    // Close the registration race: if state changed before the waiter was installed,
    // resolve immediately instead of sleeping for the whole timeout.
    const current = await this.currentOperationState(requestId);
    if (current.terminal || !current.active || current.active.status !== expectedStatus) {
      this.resolveWaiters(requestId, current.terminal || current.active || null);
    }

    const timeoutController = new AbortController();
    const timeoutPromise = scheduler
      .wait(timeoutMs, { signal: timeoutController.signal })
      .then(() => null)
      .catch((error) => {
        if (error?.name === "AbortError") return undefined;
        throw error;
      });

    try {
      await Promise.race([changePromise, timeoutPromise]);
    } finally {
      timeoutController.abort();
      this.removeWaiter(requestId, resolveChange);
    }
  }

  async currentOperationState(requestId) {
    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const terminal = recent.find((item) => item.request_id === requestId) || null;
    const active = await this.ctx.storage.get("active_operation");
    return {
      terminal,
      active: active?.request_id === requestId ? active : null,
    };
  }

  managerTimeoutResponse(requestId, operation) {
    const active = this.ctx.storage.get("active_operation");
    return Promise.resolve(active).then((current) => managerJson(managerRotatePayload({
      requestId,
      result: "UNKNOWN",
      reason: "TIMEOUT",
      operationId: current?.request_id === requestId ? current.operation_id || null : null,
      deviceOnline: this.authenticatedSocket() !== null,
      dispatched: true,
      startedAtMs: operation.created_at_ms,
    }), 504));
  }

  async acceptResult(ws, parsed) {
    const active = await this.ctx.storage.get("active_operation");
    if (!active || active.request_id !== parsed.request_id) {
      const recent = (await this.ctx.storage.get("recent_operations")) || [];
      const known = recent.find((item) => item.request_id === parsed.request_id);
      if (known?.result === "UNKNOWN") {
        if (known.operation_id && parsed.operation_id &&
            known.operation_id !== parsed.operation_id) {
          ws.close(1008, "late operation id mismatch");
          return;
        }
        const upgraded = {
          ...known,
          operation_id: parsed.operation_id || known.operation_id || null,
          result: parsed.result,
          reason: null,
          completed_at_ms: Date.now(),
        };
        await this.storeRecentTerminal(upgraded);
        ws.send(resultAckMessage(parsed.request_id));
        return;
      }
      if (known && known.result === parsed.result &&
          (known.operation_id || null) === (parsed.operation_id || null)) {
        ws.send(resultAckMessage(parsed.request_id));
        return;
      }
      ws.close(1008, "unexpected result");
      return;
    }

    if (active.operation_id && parsed.operation_id &&
        active.operation_id !== parsed.operation_id) {
      ws.close(1008, "operation id mismatch");
      return;
    }
    if (active.status === "ACCEPTED" && !parsed.operation_id) {
      ws.close(1008, "accepted operation lost id");
      return;
    }

    const terminal = {
      ...active,
      operation_id: parsed.operation_id || active.operation_id || null,
      status: "TERMINAL",
      result: parsed.result,
      reason: null,
      completed_at_ms: Date.now(),
    };
    await this.storeRecentTerminal(terminal);
    await this.ctx.storage.delete("active_operation");
    await this.ctx.storage.deleteAlarm();
    this.resolveWaiters(parsed.request_id, terminal);
    ws.send(resultAckMessage(parsed.request_id));
  }

  operationResponse(operation) {
    const status = operation.result === "UNKNOWN" ? 504 : 200;
    return managerJson(
      terminalOperationPayload(operation, this.authenticatedSocket() !== null),
      status,
    );
  }

  async alarm() {
    await this.reconcileActiveOperation(Date.now(), { fenceSockets: true });
  }

  async reconcileActiveOperation(nowMs, { fenceSockets }) {
    const active = await this.ctx.storage.get("active_operation");
    if (!active) {
      await this.ctx.storage.deleteAlarm();
      return null;
    }

    if (active.status === "DISPATCHED") {
      const recoveryCount = Number.isSafeInteger(active.delivery_recovery_count)
        ? active.delivery_recovery_count
        : 0;
      // Legacy DISPATCHED records did not persist an ACK deadline. Treat their first
      // observation as immediately due for the one safe same-request reconnect recovery.
      const deliveryDeadlineMs = Number.isSafeInteger(active.delivery_deadline_ms)
        ? active.delivery_deadline_ms
        : nowMs;

      if (nowMs < deliveryDeadlineMs) {
        await this.ctx.storage.setAlarm(deliveryDeadlineMs);
        return active;
      }

      if (recoveryCount === 0) {
        const recovering = {
          ...active,
          delivery_recovery_count: 1,
          delivery_deadline_ms: nowMs + RECOVERY_DELIVERY_ACK_MS,
        };
        await this.ctx.storage.put("active_operation", recovering);
        await this.ctx.storage.setAlarm(recovering.delivery_deadline_ms);
        if (fenceSockets) this.recoverAuthenticatedSockets();
        this.resolveWaiters(active.request_id, recovering);
        return recovering;
      }

      const fenced = {
        ...active,
        status: "FENCED",
        delivery_deadline_ms: null,
        fenced_at_ms: nowMs,
        release_at_ms: nowMs + FENCED_DRAIN_MS,
      };
      await this.ctx.storage.put("active_operation", fenced);
      await this.ctx.storage.setAlarm(fenced.release_at_ms);
      if (fenceSockets) this.fenceAuthenticatedSockets();
      this.resolveWaiters(active.request_id, fenced);
      return fenced;
    }

    if (active.status === "ACCEPTED") {
      // Pre-fix records have no accepted_at_ms. Start a fresh conservative lease on first
      // observation rather than guessing when the historical acceptance happened.
      if (!Number.isSafeInteger(active.accepted_at_ms)) {
        const migrated = { ...active, accepted_at_ms: nowMs };
        await this.ctx.storage.put("active_operation", migrated);
        await this.ctx.storage.setAlarm(nowMs + ACCEPTED_RESULT_LEASE_MS);
        return migrated;
      }

      const releaseAtMs = active.accepted_at_ms + ACCEPTED_RESULT_LEASE_MS;
      if (nowMs < releaseAtMs) {
        await this.ctx.storage.setAlarm(releaseAtMs);
        return active;
      }
      return this.finalizeUnknown(active, nowMs);
    }

    if (active.status === "FENCED") {
      const releaseAtMs = Number.isSafeInteger(active.release_at_ms)
        ? active.release_at_ms
        : nowMs + FENCED_DRAIN_MS;
      if (!Number.isSafeInteger(active.release_at_ms)) {
        const migrated = {
          ...active,
          fenced_at_ms: Number.isSafeInteger(active.fenced_at_ms)
            ? active.fenced_at_ms
            : nowMs,
          release_at_ms: releaseAtMs,
        };
        await this.ctx.storage.put("active_operation", migrated);
      }
      if (nowMs < releaseAtMs) {
        await this.ctx.storage.setAlarm(releaseAtMs);
        return active;
      }
      return this.finalizeUnknown(active, nowMs);
    }

    throw new Error("invalid persisted active operation state");
  }

  async finalizeUnknown(active, nowMs) {
    const terminal = {
      ...active,
      status: "TERMINAL",
      result: "UNKNOWN",
      reason: "TIMEOUT",
      completed_at_ms: nowMs,
    };
    await this.storeRecentTerminal(terminal);
    await this.ctx.storage.delete("active_operation");
    await this.ctx.storage.deleteAlarm();
    this.resolveWaiters(active.request_id, terminal);
    return terminal;
  }

  async storeRecentTerminal(terminal) {
    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const bounded = [terminal, ...recent.filter((item) => item.request_id !== terminal.request_id)]
      .slice(0, MAX_RECENT_OPERATIONS);
    await this.ctx.storage.put("recent_operations", bounded);
  }

  recoverAuthenticatedSockets() {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind !== "device" || attachment.authenticated !== true) continue;
      socket.serializeAttachment({ ...attachment, authenticated: false });
      socket.close(1012, "delivery recovery");
    }
  }

  fenceAuthenticatedSockets() {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind !== "device" || attachment.authenticated !== true) continue;
      socket.serializeAttachment({ ...attachment, authenticated: false });
      socket.close(1000, "operation fenced");
    }
  }

  resolveWaiters(requestId, terminal) {
    const waiters = this.waiters.get(requestId);
    if (!waiters) return;
    this.waiters.delete(requestId);
    for (const resolve of waiters) resolve(terminal);
  }

  removeWaiter(requestId, resolve) {
    const waiters = this.waiters.get(requestId);
    if (!waiters) return;
    waiters.delete(resolve);
    if (waiters.size === 0) this.waiters.delete(requestId);
  }

  authenticatedSocket() {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind === "device" && attachment.authenticated === true) return socket;
    }
    return null;
  }
}

function primaryDeviceStub(env) {
  const id = env.DEVICE_CONTROL.idFromName(PRIMARY_DEVICE_OBJECT);
  return env.DEVICE_CONTROL.get(id);
}

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
