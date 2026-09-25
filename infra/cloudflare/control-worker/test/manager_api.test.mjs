import assert from "node:assert/strict";
import test from "node:test";
import worker from "../src/index.mjs";
import {
  MANAGER_ROTATE_SCHEMA,
  MANAGER_ROTATE_WAIT_TIMEOUT_MS,
  managerJson,
  managerRotatePayload,
  newManagerRequestId,
  terminalOperationPayload,
} from "../src/manager_api.mjs";

const TOKEN = "m".repeat(40);

test("manager HTTP wait stays below Durable Object inactive-eviction territory", () => {
  assert.equal(MANAGER_ROTATE_WAIT_TIMEOUT_MS, 18_000);
});

test("manager response schema is stable and typed", () => {
  const payload = managerRotatePayload({
    requestId: "mgr_test",
    result: "CHANGED",
    reason: "NONE",
    operationId: 7,
    deviceOnline: true,
    dispatched: true,
    startedAtMs: 100,
    completedAtMs: 140,
  });
  assert.deepEqual(Object.keys(payload), [
    "schema",
    "request_id",
    "terminal",
    "result",
    "reason",
    "operation_id",
    "changed",
    "device_online",
    "dispatched",
    "retryable",
    "timing",
  ]);
  assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
  assert.equal(payload.changed, true);
  assert.equal(payload.terminal, true);
  assert.equal(payload.retryable, false);
  assert.deepEqual(payload.timing, {
    started_at_ms: 100,
    completed_at_ms: 140,
    duration_ms: 40,
  });
});

test("bounded stale correlation maps to typed UNKNOWN/TIMEOUT without blind retry", () => {
  const payload = terminalOperationPayload({
    request_id: "mgr_stale",
    status: "TERMINAL",
    operation_id: 77,
    result: "UNKNOWN",
    reason: "TIMEOUT",
    created_at_ms: 100,
    completed_at_ms: 200,
  }, false);
  assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
  assert.equal(payload.terminal, false);
  assert.equal(payload.result, "UNKNOWN");
  assert.equal(payload.reason, "TIMEOUT");
  assert.equal(payload.operation_id, 77);
  assert.equal(payload.changed, null);
  assert.equal(payload.device_online, false);
  assert.equal(payload.dispatched, true);
  assert.equal(payload.retryable, false);
});

test("server-generated manager request ids are bounded protocol-safe values", () => {
  const first = newManagerRequestId();
  const second = newManagerRequestId();
  assert.match(first, /^mgr_[0-9a-f]{32}$/u);
  assert.match(second, /^mgr_[0-9a-f]{32}$/u);
  assert.notEqual(first, second);
  assert.ok(first.length <= 64);
});

test("terminal PRODUCT results map to the one manager schema", () => {
  const base = {
    request_id: "mgr_terminal",
    status: "TERMINAL",
    operation_id: 9,
    created_at_ms: 100,
    completed_at_ms: 200,
  };
  assert.equal(terminalOperationPayload({ ...base, result: "CHANGED" }).result, "CHANGED");
  assert.equal(terminalOperationPayload({ ...base, result: "UNCHANGED" }).changed, false);
  assert.equal(terminalOperationPayload({ ...base, result: "FAILED" }).reason, "PRODUCT_FAILED");
  assert.equal(
    terminalOperationPayload({ ...base, result: "REJECTED", operation_id: null }).reason,
    "PRODUCT_REJECTED",
  );
});

test("public rotate requires manager auth and does not touch the device broker on rejection", async () => {
  let calls = 0;
  const env = managerEnv(async () => {
    calls += 1;
    throw new Error("must not be called");
  });

  let response = await worker.fetch(new Request("https://mish.alegria.by/v1/rotate", {
    method: "POST",
  }), env);
  assert.equal(response.status, 401);
  let payload = await response.json();
  assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
  assert.equal(payload.result, "REJECTED");
  assert.equal(payload.reason, "UNAUTHORIZED");
  assert.equal(payload.request_id, null);
  assert.equal(payload.dispatched, false);

  response = await worker.fetch(new Request("https://mish.alegria.by/v1/rotate", {
    method: "POST",
    headers: { Authorization: `Bearer ${"n".repeat(40)}` },
  }), env);
  assert.equal(response.status, 401);
  payload = await response.json();
  assert.equal(payload.reason, "UNAUTHORIZED");
  assert.equal(calls, 0);
});

test("public rotate accepts no caller body and generates correlation inside Worker", async () => {
  const seen = [];
  const env = managerEnv(async (request) => {
    const url = new URL(request.url);
    assert.equal(url.pathname, "/manager/rotate-and-wait");
    const body = await request.json();
    seen.push(body.request_id);
    return managerJson(managerRotatePayload({
      requestId: body.request_id,
      result: "UNCHANGED",
      reason: "NONE",
      operationId: 21,
      deviceOnline: true,
      dispatched: true,
      startedAtMs: 10,
      completedAtMs: 20,
    }));
  });

  for (let index = 0; index < 2; index += 1) {
    const response = await worker.fetch(new Request("https://mish.alegria.by/v1/rotate", {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
    }), env);
    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
    assert.equal(payload.result, "UNCHANGED");
    assert.match(payload.request_id, /^mgr_[0-9a-f]{32}$/u);
  }

  assert.equal(seen.length, 2);
  assert.notEqual(seen[0], seen[1]);
  assert.deepEqual(env.DEVICE_CONTROL.names, ["primary", "primary"]);
});

test("public rotate rejects any caller-supplied request body before correlation is created", async () => {
  let calls = 0;
  const env = managerEnv(async () => {
    calls += 1;
    throw new Error("must not be called");
  });
  const response = await worker.fetch(new Request("https://mish.alegria.by/v1/rotate", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: '{"request_id":"caller_owned"}',
  }), env);

  assert.equal(response.status, 400);
  const payload = await response.json();
  assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
  assert.equal(payload.result, "REJECTED");
  assert.equal(payload.reason, "INVALID_REQUEST");
  assert.equal(payload.request_id, null);
  assert.equal(calls, 0);
});

test("manager transport uncertainty is typed UNKNOWN and non-retryable", async () => {
  const env = managerEnv(async () => {
    throw new Error("subrequest transport failed");
  });
  const response = await worker.fetch(new Request("https://mish.alegria.by/v1/rotate", {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}` },
  }), env);

  assert.equal(response.status, 502);
  const payload = await response.json();
  assert.equal(payload.schema, MANAGER_ROTATE_SCHEMA);
  assert.match(payload.request_id, /^mgr_[0-9a-f]{32}$/u);
  assert.equal(payload.terminal, false);
  assert.equal(payload.result, "UNKNOWN");
  assert.equal(payload.reason, "INTERNAL_ERROR");
  assert.equal(payload.dispatched, null);
  assert.equal(payload.retryable, false);
});

test("old manager rotate and polling paths are not part of the public API", async () => {
  const device = "a".repeat(64);
  const env = managerEnv(async () => {
    throw new Error("must not be called");
  });
  for (const path of [
    `/v1/devices/${device}/rotate`,
    `/v1/devices/${device}/operations/old_request`,
  ]) {
    const response = await worker.fetch(new Request(`https://mish.alegria.by${path}`, {
      method: path.endsWith("/rotate") ? "POST" : "GET",
      headers: { Authorization: `Bearer ${TOKEN}` },
    }), env);
    assert.equal(response.status, 404);
  }
});

test("device transport host does not expose the public manager API", async () => {
  let calls = 0;
  const env = managerEnv(async () => {
    calls += 1;
    throw new Error("must not be called");
  });
  const response = await worker.fetch(new Request("https://api.alegria.by/v1/rotate", {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}` },
  }), env);
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "NOT_FOUND" });
  assert.equal(calls, 0);
});

test("old api hostname does not expose the device WebSocket endpoint", async () => {
  const device = "a".repeat(64);
  const env = managerEnv(async () => {
    throw new Error("must not be called");
  });
  const response = await worker.fetch(new Request(
    `https://api.alegria.by/v1/device/connect?device_id=${device}`,
    { headers: { Upgrade: "websocket" } },
  ), env);
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "NOT_FOUND" });
});

function managerEnv(fetchImpl) {
  const namespace = new FakeNamespace(fetchImpl);
  return {
    MISH_MANAGER_TOKEN: TOKEN,
    DEVICE_CONTROL: namespace,
  };
}

class FakeNamespace {
  constructor(fetchImpl) {
    this.fetchImpl = fetchImpl;
    this.names = [];
  }

  idFromName(name) {
    this.names.push(name);
    return name;
  }

  get() {
    return { fetch: this.fetchImpl };
  }
}
