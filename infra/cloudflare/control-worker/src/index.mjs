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

// PRODUCT owns mutation timing. CONTROL owns only delivery correlation.
// Rust/Tokio owns WSS liveness/reconnect continuously; Manager requests never own reconnect.
const PRODUCT_ROTATION_SAFETY_MS = 90_000;
const CONTROL_DELIVERY_MARGIN_MS = 30_000;
const ACCEPTED_RESULT_LEASE_MS = PRODUCT_ROTATION_SAFETY_MS + CONTROL_DELIVERY_MARGIN_MS;
const DELIVERY_ACK_MS = 2_000;
const FENCED_DRAIN_MS = PRODUCT_ROTATION_SAFETY_MS + CONTROL_DELIVERY_MARGIN_MS;
const CONTROL_HEARTBEAT_REQUEST = "MISH_CONTROL_HEARTBEAT_V1";
const CONTROL_HEARTBEAT_RESPONSE = "MISH_CONTROL_HEARTBEAT_ACK_V1";
const CONTROL_SESSION_FRESHNESS_MS = 10_000;

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

    // Cloudflare can answer this tiny liveness probe while the Durable Object is hibernated.
    // The Rust client owns heartbeat cadence and reconnect; the Worker only observes freshness.
    if (typeof WebSocketRequestResponsePair === "function" &&
        typeof this.ctx.setWebSocketAutoResponse === "function") {
      this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(
        CONTROL_HEARTBEAT_REQUEST,
        CONTROL_HEARTBEAT_RESPONSE,
      ));
    }
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
        authenticated_at_ms: Date.now(),
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
      // Legacy records without a delivery deadline are due immediately. There is no
      // manager-owned recovery pass: the native control session continuously owns reconnect.
      const deliveryDeadlineMs = Number.isSafeInteger(active.delivery_deadline_ms)
        ? active.delivery_deadline_ms
        : nowMs;

      if (nowMs < deliveryDeadlineMs) {
        await this.ctx.storage.setAlarm(deliveryDeadlineMs);
        return active;
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

  freshAuthenticatedSocket(nowMs = Date.now()) {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind !== "device" || attachment.authenticated !== true) continue;

      const authenticatedAtMs = Number.isSafeInteger(attachment.authenticated_at_ms)
        ? attachment.authenticated_at_ms
        : null;
      const autoResponseAt = typeof this.ctx.getWebSocketAutoResponseTimestamp === "function"
        ? this.ctx.getWebSocketAutoResponseTimestamp(socket)
        : null;
      const heartbeatAtMs = autoResponseAt instanceof Date
        ? autoResponseAt.getTime()
        : null;
      const freshestAtMs = Math.max(
        authenticatedAtMs ?? Number.NEGATIVE_INFINITY,
        Number.isSafeInteger(heartbeatAtMs) ? heartbeatAtMs : Number.NEGATIVE_INFINITY,
      );
      if (Number.isFinite(freshestAtMs) &&
          freshestAtMs <= nowMs &&
          nowMs - freshestAtMs <= CONTROL_SESSION_FRESHNESS_MS) {
        return socket;
      }
    }
    return null;
  }

  closeStaleAuthenticatedSockets(nowMs = Date.now()) {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind !== "device" || attachment.authenticated !== true) continue;

      const authenticatedAtMs = Number.isSafeInteger(attachment.authenticated_at_ms)
        ? attachment.authenticated_at_ms
        : null;
      const autoResponseAt = typeof this.ctx.getWebSocketAutoResponseTimestamp === "function"
        ? this.ctx.getWebSocketAutoResponseTimestamp(socket)
        : null;
      const heartbeatAtMs = autoResponseAt instanceof Date
        ? autoResponseAt.getTime()
        : null;
      const freshestAtMs = Math.max(
        authenticatedAtMs ?? Number.NEGATIVE_INFINITY,
        Number.isSafeInteger(heartbeatAtMs) ? heartbeatAtMs : Number.NEGATIVE_INFINITY,
      );
      if (!Number.isFinite(freshestAtMs) ||
          freshestAtMs > nowMs ||
          nowMs - freshestAtMs > CONTROL_SESSION_FRESHNESS_MS) {
        socket.serializeAttachment({ ...attachment, authenticated: false });
        socket.close(1012, "stale control session");
      }
    }
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
