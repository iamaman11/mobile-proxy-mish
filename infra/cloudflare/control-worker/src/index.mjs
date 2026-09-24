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
      active.status = "ACCEPTED";
      await this.ctx.storage.put("active_operation", active);
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
      return managerJson(terminalOperationPayload(
        dispatch.operation,
        this.authenticatedSocket() !== null,
      ));
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
      completed_at_ms: null,
    };
    await this.ctx.storage.put("active_operation", operation);
    try {
      socket.send(rotateMessage(requestId));
    } catch {
      await this.ctx.storage.delete("active_operation");
      return { kind: "DEVICE_OFFLINE" };
    }
    return { kind: "DISPATCHED", operation };
  }

  async waitForTerminal(requestId, operation) {
    let resolveTerminal;
    const terminalPromise = new Promise((resolve) => {
      resolveTerminal = resolve;
      let waiters = this.waiters.get(requestId);
      if (!waiters) {
        waiters = new Set();
        this.waiters.set(requestId, waiters);
      }
      waiters.add(resolve);
    });

    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const alreadyTerminal = recent.find((item) => item.request_id === requestId);
    if (alreadyTerminal) {
      this.resolveWaiters(requestId, alreadyTerminal);
      return managerJson(terminalOperationPayload(
        alreadyTerminal,
        this.authenticatedSocket() !== null,
      ));
    }

    const timeoutController = new AbortController();
    const timeoutPromise = scheduler
      .wait(MANAGER_ROTATE_WAIT_TIMEOUT_MS, { signal: timeoutController.signal })
      .then(() => null)
      .catch((error) => {
        if (error?.name === "AbortError") return undefined;
        throw error;
      });

    let terminal;
    try {
      terminal = await Promise.race([terminalPromise, timeoutPromise]);
    } finally {
      timeoutController.abort();
      this.removeWaiter(requestId, resolveTerminal);
    }

    if (terminal) {
      return managerJson(terminalOperationPayload(
        terminal,
        this.authenticatedSocket() !== null,
      ));
    }

    const finalRecent = (await this.ctx.storage.get("recent_operations")) || [];
    const finalTerminal = finalRecent.find((item) => item.request_id === requestId);
    if (finalTerminal) {
      return managerJson(terminalOperationPayload(
        finalTerminal,
        this.authenticatedSocket() !== null,
      ));
    }

    const active = await this.ctx.storage.get("active_operation");
    return managerJson(managerRotatePayload({
      requestId,
      result: "UNKNOWN",
      reason: "TIMEOUT",
      operationId: active?.request_id === requestId ? active.operation_id || null : null,
      deviceOnline: this.authenticatedSocket() !== null,
      dispatched: true,
      startedAtMs: operation.created_at_ms,
    }), 504);
  }

  async acceptResult(ws, parsed) {
    const active = await this.ctx.storage.get("active_operation");
    if (!active || active.request_id !== parsed.request_id) {
      const recent = (await this.ctx.storage.get("recent_operations")) || [];
      const known = recent.find((item) => item.request_id === parsed.request_id);
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
      completed_at_ms: Date.now(),
    };
    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const bounded = [terminal, ...recent.filter((item) => item.request_id !== terminal.request_id)]
      .slice(0, MAX_RECENT_OPERATIONS);

    await this.ctx.storage.put("recent_operations", bounded);
    await this.ctx.storage.delete("active_operation");
    this.resolveWaiters(parsed.request_id, terminal);
    ws.send(resultAckMessage(parsed.request_id));
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
