import {
  MAX_RECENT_OPERATIONS,
  canonicalAuthPayload,
  challengeMessage,
  deviceIdFromSpkiB64,
  isDeviceId,
  isFreshAuthChallenge,
  isRequestId,
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
const DEVICE_TAG = "authenticated-device";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === DEVICE_CONNECT) {
      const deviceId = url.searchParams.get("device_id");
      if (!isDeviceId(deviceId) || url.searchParams.size !== 1 ||
          request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "INVALID_DEVICE_REQUEST" }, 400);
      }
      return deviceStub(env, deviceId).fetch(
        new Request(`https://control.internal/device/connect?device_id=${deviceId}`, request),
      );
    }

    const match = url.pathname.match(
      /^\/v1\/devices\/([0-9a-f]{64})(?:\/(rotate|operations\/([A-Za-z0-9_-]{1,64})))?$/u,
    );
    if (!match || !(await managerAuthorized(request, env.MISH_MANAGER_TOKEN))) {
      return json({ error: match ? "UNAUTHORIZED" : "NOT_FOUND" }, match ? 401 : 404);
    }

    const deviceId = match[1];
    if (!match[2] && request.method === "PUT") {
      let enrollment;
      try {
        enrollment = parseEnrollmentBody(await readBoundedJson(request));
      } catch {
        return json({ error: "INVALID_ENROLLMENT" }, 400);
      }
      if ((await deviceIdFromSpkiB64(enrollment.public_key_spki_b64)) !== deviceId) {
        return json({ error: "DEVICE_ID_PUBLIC_KEY_MISMATCH" }, 400);
      }
      return deviceStub(env, deviceId).fetch(new Request("https://control.internal/manager/enroll", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(enrollment),
      }));
    }

    if (match[2] === "rotate" && request.method === "POST") {
      let command;
      try {
        command = parseManagerRotateBody(await readBoundedJson(request));
      } catch {
        return json({ error: "INVALID_ROTATE_REQUEST" }, 400);
      }
      return deviceStub(env, deviceId).fetch(new Request("https://control.internal/manager/rotate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(command),
      }));
    }

    if (match[3] && request.method === "GET" && isRequestId(match[3])) {
      return deviceStub(env, deviceId).fetch(
        new Request(`https://control.internal/manager/operation?request_id=${match[3]}`),
      );
    }

    return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  },
};

export class DeviceControl {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/device/connect") return this.connectDevice(request);
    if (url.pathname === "/manager/enroll" && request.method === "PUT") return this.enroll(request);
    if (url.pathname === "/manager/rotate" && request.method === "POST") return this.rotate(request);
    if (url.pathname === "/manager/operation" && request.method === "GET") return this.operation(url);
    return json({ error: "NOT_FOUND" }, 404);
  }

  async enroll(request) {
    const body = parseEnrollmentBody(await readBoundedJson(request));
    const current = await this.ctx.storage.get("public_key_spki_b64");
    if (current && current !== body.public_key_spki_b64) {
      return json({ error: "IDENTITY_ALREADY_BOUND" }, 409);
    }
    await this.ctx.storage.put("public_key_spki_b64", body.public_key_spki_b64);
    return json({ enrolled: true }, 200);
  }

  async connectDevice(request) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "WEBSOCKET_REQUIRED" }, 426);
    }
    const enrolled = await this.ctx.storage.get("public_key_spki_b64");
    if (!enrolled) return json({ error: "DEVICE_NOT_ENROLLED" }, 404);

    const url = new URL(request.url);
    const deviceId = url.searchParams.get("device_id");
    if (!isDeviceId(deviceId)) return json({ error: "INVALID_DEVICE_ID" }, 400);

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
      const spki = await this.ctx.storage.get("public_key_spki_b64");
      if (!spki || !attachment.challenge) {
        ws.close(1008, "identity unavailable");
        return;
      }
      if (!isFreshAuthChallenge(attachment.challenge_issued_at_ms)) {
        ws.close(1008, "authentication expired");
        return;
      }
      const valid = await verifyDeviceSignature(
        spki,
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
        if (other?.authenticated === true) existing.close(1000, "replaced");
      }
      ws.serializeAttachment({
        kind: "device",
        authenticated: true,
        device_id: attachment.device_id,
      });
      ws.send(readyMessage());
      return;
    }

    if (parsed.type === "ACCEPTED") {
      const active = await this.ctx.storage.get("active_operation");
      if (!active || active.request_id !== parsed.request_id) {
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

  async rotate(request) {
    const command = parseManagerRotateBody(await readBoundedJson(request));
    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const known = recent.find((item) => item.request_id === command.request_id);
    if (known) return json(publicOperation(known), 200);

    const active = await this.ctx.storage.get("active_operation");
    if (active) {
      if (active.request_id === command.request_id) return json(publicOperation(active), 200);
      return json({
        error: "BUSY",
        active_request_id: active.request_id,
        operation_id: active.operation_id || null,
      }, 409);
    }

    const socket = this.authenticatedSocket();
    if (!socket) return json({ error: "DEVICE_OFFLINE" }, 409);

    const operation = {
      request_id: command.request_id,
      status: "DISPATCHED",
      operation_id: null,
      result: null,
      created_at_ms: Date.now(),
      completed_at_ms: null,
    };
    await this.ctx.storage.put("active_operation", operation);
    try {
      socket.send(rotateMessage(command.request_id));
    } catch {
      await this.ctx.storage.delete("active_operation");
      return json({ error: "DEVICE_OFFLINE" }, 409);
    }
    return json(publicOperation(operation), 202);
  }

  async operation(url) {
    const requestId = url.searchParams.get("request_id");
    if (!isRequestId(requestId) || url.searchParams.size !== 1) {
      return json({ error: "INVALID_REQUEST_ID" }, 400);
    }
    const active = await this.ctx.storage.get("active_operation");
    if (active?.request_id === requestId) return json(publicOperation(active), 200);
    const recent = (await this.ctx.storage.get("recent_operations")) || [];
    const known = recent.find((item) => item.request_id === requestId);
    return known ? json(publicOperation(known), 200) : json({ error: "NOT_FOUND" }, 404);
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
    ws.send(resultAckMessage(parsed.request_id));
  }

  authenticatedSocket() {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.kind === "device" && attachment.authenticated === true) return socket;
    }
    return null;
  }
}

function deviceStub(env, deviceId) {
  const id = env.DEVICE_CONTROL.idFromName(deviceId);
  return env.DEVICE_CONTROL.get(id);
}

function publicOperation(operation) {
  return {
    request_id: operation.request_id,
    status: operation.status,
    operation_id: operation.operation_id || null,
    result: operation.result || null,
    created_at_ms: operation.created_at_ms,
    completed_at_ms: operation.completed_at_ms || null,
  };
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
