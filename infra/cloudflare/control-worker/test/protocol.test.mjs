import assert from "node:assert/strict";
import test from "node:test";
import { DeviceControl } from "../src/index.mjs";
import {
  DEVICE_AUTH_CHALLENGE_MAX_AGE_MS,
  MAX_RECENT_OPERATIONS,
  base64UrlEncode,
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
  readyMessage,
  resultAckMessage,
  rotateMessage,
  verifyDeviceSignature,
} from "../src/protocol.mjs";

globalThis.WebSocketRequestResponsePair = class {
  constructor(request, response) {
    this.request = request;
    this.response = response;
  }
};

test("wire vocabulary is narrow and versioned", () => {
  const nonce = "a".repeat(43);
  assert.deepEqual(JSON.parse(challengeMessage(nonce)), {
    type: "CHALLENGE", v: 1, nonce,
  });
  assert.deepEqual(JSON.parse(readyMessage()), { type: "READY", v: 1 });
  assert.deepEqual(JSON.parse(rotateMessage("req_1")), {
    type: "ROTATE_IP", v: 1, request_id: "req_1",
  });
  assert.deepEqual(JSON.parse(resultAckMessage("req_1")), {
    type: "RESULT_ACK", v: 1, request_id: "req_1",
  });
});

test("device parser rejects unknown commands, fields and bad operation ids", () => {
  assert.throws(() => parseDeviceMessage('{"v":1,"type":"SHELL"}'));
  assert.throws(() => parseDeviceMessage(
    '{"v":1,"type":"ACCEPTED","request_id":"req","operation_id":0}',
  ));
  assert.throws(() => parseDeviceMessage(
    '{"v":1,"type":"AUTH","device_id":"' + "a".repeat(64) +
    '","signature":"' + "b".repeat(86) + '","extra":1}',
  ));

  const accepted = parseDeviceMessage(
    '{"v":1,"type":"ACCEPTED","request_id":"req","operation_id":7}',
  );
  assert.equal(accepted.operation_id, 7);
});

test("terminal result permits rejected without mutation id only", () => {
  const rejected = parseDeviceMessage(
    '{"v":1,"type":"RESULT","request_id":"r","result":"REJECTED"}',
  );
  assert.equal(rejected.result, "REJECTED");
  const rejectedAfterFailedAcceptance = parseDeviceMessage(
    '{"v":1,"type":"RESULT","request_id":"r","result":"REJECTED","operation_id":7}',
  );
  assert.equal(rejectedAfterFailedAcceptance.operation_id, 7);
  assert.throws(() => parseDeviceMessage(
    '{"v":1,"type":"RESULT","request_id":"r","result":"CHANGED"}',
  ));
  const changed = parseDeviceMessage(
    '{"v":1,"type":"RESULT","request_id":"r","result":"CHANGED","operation_id":9}',
  );
  assert.equal(changed.operation_id, 9);
});

test("manager bodies and identities are strict", () => {
  assert.deepEqual(parseManagerRotateBody({ request_id: "abc_123" }), {
    request_id: "abc_123",
  });
  assert.throws(() => parseManagerRotateBody({ request_id: "abc", command: "shell" }));
  assert.ok(isRequestId("abc-123"));
  assert.ok(!isRequestId("bad space"));
  assert.ok(isDeviceId("a".repeat(64)));
  assert.ok(!isDeviceId("A".repeat(64)));

  assert.deepEqual(
    parseEnrollmentBody({ public_key_spki_b64: "A".repeat(100) }),
    { public_key_spki_b64: "A".repeat(100) },
  );
  assert.throws(() => parseEnrollmentBody({ public_key_spki_b64: "short" }));
});

test("auth payload exactly matches Rust domain format", () => {
  const device = "1".repeat(64);
  const nonce = "z".repeat(43);
  assert.equal(
    new TextDecoder().decode(canonicalAuthPayload(device, nonce)),
    `MISH_CONTROL_AUTH_V1\n${device}\n${nonce}`,
  );
});


test("manager auth is exact and fail-closed", async () => {
  const token = "m".repeat(40);
  const authorized = new Request("https://control.test/v1/devices/" + "a".repeat(64), {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(await managerAuthorized(authorized, token), true);

  const wrong = new Request("https://control.test/", {
    headers: { Authorization: `Bearer ${"n".repeat(40)}` },
  });
  assert.equal(await managerAuthorized(wrong, token), false);
  assert.equal(await managerAuthorized(new Request("https://control.test/"), token), false);
  assert.equal(await managerAuthorized(authorized, "short"), false);
});

test("device challenge is bounded, tamper-safe and non-replayable", async () => {
  const now = 10_000_000;
  assert.equal(isFreshAuthChallenge(now, now), true);
  assert.equal(
    isFreshAuthChallenge(now - DEVICE_AUTH_CHALLENGE_MAX_AGE_MS, now),
    true,
  );
  assert.equal(
    isFreshAuthChallenge(now - DEVICE_AUTH_CHALLENGE_MAX_AGE_MS - 1, now),
    false,
  );
  assert.equal(isFreshAuthChallenge(now + 1, now), false);

  const identity = await generateIdentity();
  const nonce = "a".repeat(43);
  const signature = await signAuth(identity.keyPair.privateKey, identity.deviceId, nonce);
  assert.equal(
    await verifyDeviceSignature(
      identity.spkiB64,
      signature,
      canonicalAuthPayload(identity.deviceId, nonce),
    ),
    true,
  );
  assert.equal(
    await verifyDeviceSignature(
      identity.spkiB64,
      signature,
      canonicalAuthPayload(identity.deviceId, "b".repeat(43)),
    ),
    false,
  );

  const storage = new MemoryStorage();
  await storage.put("device_identity", { device_id: identity.deviceId, public_key_spki_b64: identity.spkiB64 });
  const socket = new FakeSocket({
    kind: "device",
    authenticated: false,
    device_id: identity.deviceId,
    challenge: nonce,
    challenge_issued_at_ms: Date.now(),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});
  await control.webSocketMessage(socket, JSON.stringify({
    v: 1,
    type: "AUTH",
    device_id: identity.deviceId,
    signature,
  }));
  assert.equal(socket.attachment.authenticated, true);
  assert.deepEqual(JSON.parse(socket.sent.at(-1)), { type: "READY", v: 1 });

  const replaySocket = new FakeSocket({
    kind: "device",
    authenticated: false,
    device_id: identity.deviceId,
    challenge: "b".repeat(43),
    challenge_issued_at_ms: Date.now(),
  });
  const replayControl = new DeviceControl(new FakeContext(storage, [replaySocket]), {});
  await replayControl.webSocketMessage(replaySocket, JSON.stringify({
    v: 1,
    type: "AUTH",
    device_id: identity.deviceId,
    signature,
  }));
  assert.equal(replaySocket.closed.at(-1)?.reason, "authentication failed");

  const expiredSocket = new FakeSocket({
    kind: "device",
    authenticated: false,
    device_id: identity.deviceId,
    challenge: nonce,
    challenge_issued_at_ms: Date.now() - DEVICE_AUTH_CHALLENGE_MAX_AGE_MS - 1,
  });
  const expiredControl = new DeviceControl(new FakeContext(storage, [expiredSocket]), {});
  await expiredControl.webSocketMessage(expiredSocket, JSON.stringify({
    v: 1,
    type: "AUTH",
    device_id: identity.deviceId,
    signature,
  }));
  assert.equal(expiredSocket.closed.at(-1)?.reason, "authentication expired");
});

test("replacement authentication retires the old socket before broker selection", async () => {
  const identity = await generateIdentity();
  const nonce = "c".repeat(43);
  const signature = await signAuth(identity.keyPair.privateKey, identity.deviceId, nonce);
  const storage = new MemoryStorage();
  await storage.put("device_identity", { device_id: identity.deviceId, public_key_spki_b64: identity.spkiB64 });

  const oldSocket = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: identity.deviceId,
  });
  const newSocket = new FakeSocket({
    kind: "device",
    authenticated: false,
    device_id: identity.deviceId,
    challenge: nonce,
    challenge_issued_at_ms: Date.now(),
  });
  const control = new DeviceControl(new FakeContext(storage, [oldSocket, newSocket]), {});

  await control.webSocketMessage(newSocket, JSON.stringify({
    v: 1,
    type: "AUTH",
    device_id: identity.deviceId,
    signature,
  }));

  assert.equal(oldSocket.attachment.authenticated, false);
  assert.equal(oldSocket.closed.at(-1)?.reason, "replaced");
  assert.equal(newSocket.attachment.authenticated, true);
  assert.equal(control.freshAuthenticatedSocket(), newSocket);
});

test("authenticated reattach never makes Worker a reconnect-redelivery owner", async () => {
  const identity = await generateIdentity();
  const nonce = "d".repeat(43);
  const signature = await signAuth(identity.keyPair.privateKey, identity.deviceId, nonce);
  const storage = new MemoryStorage();
  await storage.put("device_identity", {
    device_id: identity.deviceId,
    public_key_spki_b64: identity.spkiB64,
  });
  await storage.put("active_operation", {
    request_id: "req_resume",
    status: "DISPATCHED",
    operation_id: null,
    result: null,
    created_at_ms: Date.now(),
    delivery_deadline_ms: Date.now() + 2_000,
    completed_at_ms: null,
  });

  const socket = new FakeSocket({
    kind: "device",
    authenticated: false,
    device_id: identity.deviceId,
    challenge: nonce,
    challenge_issued_at_ms: Date.now(),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  await control.webSocketMessage(socket, JSON.stringify({
    v: 1,
    type: "AUTH",
    device_id: identity.deviceId,
    signature,
  }));

  assert.deepEqual(
    socket.sent.map((message) => JSON.parse(message).type),
    ["READY"],
  );
  assert.equal((await storage.get("active_operation")).request_id, "req_resume");
});

test("late duplicate acceptance after terminal correlation is harmless", async () => {
  const storage = new MemoryStorage();
  await storage.put("recent_operations", [{
    request_id: "req_terminal",
    status: "TERMINAL",
    operation_id: 17,
    result: "CHANGED",
    created_at_ms: 1,
    completed_at_ms: 2,
  }]);
  const socket = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: "a".repeat(64),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  await control.webSocketMessage(
    socket,
    '{"v":1,"type":"ACCEPTED","request_id":"req_terminal","operation_id":17}',
  );

  assert.equal(socket.closed.length, 0);
  assert.equal((await storage.get("recent_operations"))[0].result, "CHANGED");
});

test("primary enrollment is idempotent and fail-closed against identity replacement", async () => {
  const first = await generateIdentity();
  const second = await generateIdentity();
  const storage = new MemoryStorage();
  const control = new DeviceControl(new FakeContext(storage, []), {});

  let response = await control.enroll(
    enrollmentRequest(first.deviceId, first.spkiB64),
    new URL(`https://control.internal/manager/enroll?device_id=${first.deviceId}`),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await storage.get("device_identity"), {
    device_id: first.deviceId,
    public_key_spki_b64: first.spkiB64,
  });

  response = await control.enroll(
    enrollmentRequest(first.deviceId, first.spkiB64),
    new URL(`https://control.internal/manager/enroll?device_id=${first.deviceId}`),
  );
  assert.equal(response.status, 200);

  response = await control.enroll(
    enrollmentRequest(second.deviceId, second.spkiB64),
    new URL(`https://control.internal/manager/enroll?device_id=${second.deviceId}`),
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error, "IDENTITY_ALREADY_BOUND");
  assert.equal((await storage.get("device_identity")).device_id, first.deviceId);
});

test("manager immediate rejection responses share the typed schema", async () => {
  const offline = new DeviceControl(new FakeContext(new MemoryStorage(), []), {});
  let response = await offline.rotateAndWait(rotateRequest("req_offline"));
  assert.equal(response.status, 409);
  let payload = await response.json();
  assert.equal(payload.schema, "mish.control.rotate/v1");
  assert.equal(payload.result, "REJECTED");
  assert.equal(payload.reason, "DEVICE_OFFLINE");
  assert.equal(payload.dispatched, false);
  assert.equal(payload.device_online, false);
  assert.equal(payload.retryable, true);

  const storage = new MemoryStorage();
  await storage.put("active_operation", {
    request_id: "already_active",
    status: "ACCEPTED",
    operation_id: 5,
    result: null,
    created_at_ms: 1,
    completed_at_ms: null,
  });
  const socket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const busy = new DeviceControl(new FakeContext(storage, [socket]), {});
  response = await busy.rotateAndWait(rotateRequest("req_busy"));
  assert.equal(response.status, 409);
  payload = await response.json();
  assert.equal(payload.schema, "mish.control.rotate/v1");
  assert.equal(payload.result, "REJECTED");
  assert.equal(payload.reason, "BUSY");
  assert.equal(payload.dispatched, false);
  assert.equal(payload.device_online, true);
  assert.equal(payload.retryable, true);
});

test("durable broker is idempotent, busy-bounded and has no offline queue", async () => {
  const storage = new MemoryStorage();
  let activeWasStoredBeforeSend = false;
  const socket = new FakeSocket(
    { kind: "device", authenticated: true, device_id: "a".repeat(64) },
    () => {
      activeWasStoredBeforeSend = storage.data.has("active_operation");
    },
  );
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  let dispatch = await control.dispatchRotation("req_1");
  assert.equal(dispatch.kind, "DISPATCHED");
  assert.equal(socket.sent.length, 1);
  assert.equal(activeWasStoredBeforeSend, true);
  assert.ok(Number.isSafeInteger(storage.alarm));

  dispatch = await control.dispatchRotation("req_1");
  assert.equal(dispatch.kind, "ACTIVE_SAME");
  assert.equal(socket.sent.length, 1);

  dispatch = await control.dispatchRotation("req_2");
  assert.equal(dispatch.kind, "BUSY");
  assert.equal(socket.sent.length, 1);

  await control.webSocketMessage(
    socket,
    '{"v":1,"type":"ACCEPTED","request_id":"req_1","operation_id":7}',
  );
  assert.equal((await storage.get("active_operation")).status, "ACCEPTED");

  await control.webSocketMessage(
    socket,
    '{"v":1,"type":"RESULT","request_id":"req_1","result":"CHANGED","operation_id":7}',
  );
  assert.equal(await storage.get("active_operation"), undefined);
  assert.equal(storage.alarm, null);
  assert.equal((await storage.get("recent_operations"))[0].result, "CHANGED");

  dispatch = await control.dispatchRotation("req_1");
  assert.equal(dispatch.kind, "TERMINAL");
  assert.equal(socket.sent.filter((message) => JSON.parse(message).type === "ROTATE_IP").length, 1);

  const offlineStorage = new MemoryStorage();
  const offline = new DeviceControl(new FakeContext(offlineStorage, []), {});
  dispatch = await offline.dispatchRotation("offline_1");
  assert.equal(dispatch.kind, "DEVICE_OFFLINE");
  assert.equal(await offlineStorage.get("active_operation"), undefined);
});

test("accepted operation with permanently lost RESULT expires and releases BUSY", async () => {
  const storage = new MemoryStorage();
  await storage.put("active_operation", {
    request_id: "req_accepted_stale",
    status: "ACCEPTED",
    operation_id: 71,
    result: null,
    created_at_ms: 1,
    accepted_at_ms: 10,
    fenced_at_ms: null,
    release_at_ms: null,
    completed_at_ms: null,
  });
  const socket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  const terminal = await control.reconcileActiveOperation(120_011, { fenceSockets: true });
  assert.equal(terminal.status, "TERMINAL");
  assert.equal(terminal.result, "UNKNOWN");
  assert.equal(terminal.reason, "TIMEOUT");
  assert.equal(terminal.operation_id, 71);
  assert.equal(await storage.get("active_operation"), undefined);
  assert.equal(storage.alarm, null);
  assert.equal((await storage.get("recent_operations"))[0].request_id, "req_accepted_stale");

  const dispatch = await control.dispatchRotation("req_after_stale");
  assert.equal(dispatch.kind, "DISPATCHED");
  assert.equal(JSON.parse(socket.sent.at(-1)).request_id, "req_after_stale");
});

test("unaccepted dispatch fences after one 2 second ACK window and keeps the safety drain", async () => {
  const now = Date.now();
  const storage = new MemoryStorage();
  await storage.put("active_operation", {
    request_id: "req_unaccepted",
    status: "DISPATCHED",
    operation_id: null,
    result: null,
    created_at_ms: now - 2_001,
    accepted_at_ms: null,
    delivery_deadline_ms: now - 1,
    fenced_at_ms: null,
    release_at_ms: null,
    completed_at_ms: null,
  });
  const socket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  let active = await control.reconcileActiveOperation(now, { fenceSockets: true });
  assert.equal(active.status, "FENCED");
  assert.equal(active.release_at_ms, now + 120_000);
  assert.equal(socket.attachment.authenticated, false);
  assert.equal(socket.closed.at(-1)?.reason, "operation fenced");
  assert.equal(storage.alarm, now + 120_000);

  const replacementSocket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const replacementControl = new DeviceControl(
    new FakeContext(storage, [replacementSocket]),
    {},
  );
  const busy = await replacementControl.dispatchRotation("req_new_too_early");
  assert.equal(busy.kind, "BUSY");
  assert.equal(replacementSocket.sent.length, 0);

  active = await replacementControl.reconcileActiveOperation(
    now + 120_001,
    { fenceSockets: true },
  );
  assert.equal(active.result, "UNKNOWN");
  assert.equal(await storage.get("active_operation"), undefined);

  const finalSocket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const finalControl = new DeviceControl(new FakeContext(storage, [finalSocket]), {});
  const next = await finalControl.dispatchRotation("req_new_after_drain");
  assert.equal(next.kind, "DISPATCHED");
  assert.equal(JSON.parse(finalSocket.sent.at(-1)).request_id, "req_new_after_drain");
});

test("stale hibernated socket is rejected before dispatch", async () => {
  const now = Date.now();
  const storage = new MemoryStorage();
  const stale = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: "a".repeat(64),
    authenticated_at_ms: now - 20_000,
  });
  const ctx = new FakeContext(storage, [stale], { autoResponseAtMs: now - 20_000 });
  const control = new DeviceControl(ctx, {});

  const dispatch = await control.dispatchRotation("req_stale");
  assert.equal(dispatch.kind, "DEVICE_OFFLINE");
  assert.equal(stale.sent.length, 0);
  assert.equal(stale.attachment.authenticated, false);
  assert.equal(stale.closed.at(-1)?.reason, "stale control session");
  assert.equal(await storage.get("active_operation"), undefined);
});

test("fresh authentication grace and heartbeat timestamp are both valid liveness proofs", async () => {
  const now = Date.now();
  const storage = new MemoryStorage();

  const newlyAuthenticated = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: "a".repeat(64),
    authenticated_at_ms: now,
  });
  const authOnlyContext = new FakeContext(
    storage,
    [newlyAuthenticated],
    { autoResponseAtMs: null },
  );
  const authOnlyControl = new DeviceControl(authOnlyContext, {});
  assert.equal(authOnlyControl.freshAuthenticatedSocket(now), newlyAuthenticated);

  const heartbeatFresh = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: "b".repeat(64),
    authenticated_at_ms: now - 60_000,
  });
  const heartbeatContext = new FakeContext(
    new MemoryStorage(),
    [heartbeatFresh],
    { autoResponseAtMs: now - 1_000 },
  );
  const heartbeatControl = new DeviceControl(heartbeatContext, {});
  assert.equal(heartbeatControl.freshAuthenticatedSocket(now), heartbeatFresh);
  assert.equal(heartbeatContext.autoResponsePair.request, "MISH_CONTROL_HEARTBEAT_V1");
  assert.equal(heartbeatContext.autoResponsePair.response, "MISH_CONTROL_HEARTBEAT_ACK_V1");
});

test("late real RESULT upgrades stale UNKNOWN correlation and is acknowledged", async () => {
  const storage = new MemoryStorage();
  await storage.put("recent_operations", [{
    request_id: "req_late_result",
    status: "TERMINAL",
    operation_id: 81,
    result: "UNKNOWN",
    reason: "TIMEOUT",
    created_at_ms: 1,
    completed_at_ms: 200,
  }]);
  const socket = new FakeSocket({
    kind: "device", authenticated: true, device_id: "a".repeat(64),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  await control.acceptResult(socket, {
    type: "RESULT",
    request_id: "req_late_result",
    result: "CHANGED",
    operation_id: 81,
  });

  const recent = await storage.get("recent_operations");
  assert.equal(recent[0].result, "CHANGED");
  assert.equal(recent[0].operation_id, 81);
  assert.equal(recent[0].reason, null);
  assert.equal(JSON.parse(socket.sent.at(-1)).type, "RESULT_ACK");
  assert.equal(socket.closed.length, 0);
});

test("legacy ACCEPTED state gets a fresh conservative lease instead of guessed expiry", async () => {
  const storage = new MemoryStorage();
  await storage.put("active_operation", {
    request_id: "req_legacy_accepted",
    status: "ACCEPTED",
    operation_id: 91,
    result: null,
    created_at_ms: 1,
    completed_at_ms: null,
  });
  const control = new DeviceControl(new FakeContext(storage, []), {});

  const migrated = await control.reconcileActiveOperation(1_000_000, { fenceSockets: true });
  assert.equal(migrated.status, "ACCEPTED");
  assert.equal(migrated.accepted_at_ms, 1_000_000);
  assert.equal(storage.alarm, 1_120_000);
  assert.notEqual(await storage.get("active_operation"), undefined);

  const terminal = await control.reconcileActiveOperation(1_120_001, { fenceSockets: true });
  assert.equal(terminal.result, "UNKNOWN");
  assert.equal(await storage.get("active_operation"), undefined);
});

test("alarm recovery is idempotent after stale correlation is finalized", async () => {
  const storage = new MemoryStorage();
  await storage.put("active_operation", {
    request_id: "req_alarm_once",
    status: "ACCEPTED",
    operation_id: 101,
    result: null,
    created_at_ms: 1,
    accepted_at_ms: 1,
    completed_at_ms: null,
  });
  const control = new DeviceControl(new FakeContext(storage, []), {});

  const originalNow = Date.now;
  Date.now = () => 120_002;
  try {
    await control.alarm();
    await control.alarm();
  } finally {
    Date.now = originalNow;
  }

  assert.equal(await storage.get("active_operation"), undefined);
  assert.equal(storage.alarm, null);
  const recent = await storage.get("recent_operations");
  assert.equal(recent.length, 1);
  assert.equal(recent[0].result, "UNKNOWN");
});

test("manager wait is event-driven and returns one typed terminal result", async () => {
  const previousScheduler = globalThis.scheduler;
  globalThis.scheduler = { wait: () => new Promise(() => {}) };
  try {
    const storage = new MemoryStorage();
    let sentResolve;
    const sent = new Promise((resolve) => { sentResolve = resolve; });
    const socket = new FakeSocket(
      { kind: "device", authenticated: true, device_id: "a".repeat(64) },
      () => sentResolve(),
    );
    const control = new DeviceControl(new FakeContext(storage, [socket]), {});

    const responsePromise = control.rotateAndWait(rotateRequest("req_wait"));
    await sent;
    assert.equal(JSON.parse(socket.sent[0]).request_id, "req_wait");

    await control.webSocketMessage(
      socket,
      '{"v":1,"type":"ACCEPTED","request_id":"req_wait","operation_id":11}',
    );
    await control.webSocketMessage(
      socket,
      '{"v":1,"type":"RESULT","request_id":"req_wait","result":"UNCHANGED","operation_id":11}',
    );

    const response = await responsePromise;
    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.schema, "mish.control.rotate/v1");
    assert.equal(payload.request_id, "req_wait");
    assert.equal(payload.terminal, true);
    assert.equal(payload.result, "UNCHANGED");
    assert.equal(payload.reason, "NONE");
    assert.equal(payload.operation_id, 11);
    assert.equal(payload.changed, false);
    assert.equal(payload.dispatched, true);
    assert.equal(payload.retryable, false);
  } finally {
    globalThis.scheduler = previousScheduler;
  }
});

test("manager wait timeout is typed unknown and never invites blind retry", async () => {
  const previousScheduler = globalThis.scheduler;
  globalThis.scheduler = { wait: async () => {} };
  try {
    const storage = new MemoryStorage();
    const socket = new FakeSocket({
      kind: "device", authenticated: true, device_id: "a".repeat(64),
    });
    const control = new DeviceControl(new FakeContext(storage, [socket]), {});

    const response = await control.rotateAndWait(rotateRequest("req_timeout"));
    assert.equal(response.status, 504);
    const payload = await response.json();
    assert.equal(payload.schema, "mish.control.rotate/v1");
    assert.equal(payload.request_id, "req_timeout");
    assert.equal(payload.terminal, false);
    assert.equal(payload.result, "UNKNOWN");
    assert.equal(payload.reason, "TIMEOUT");
    assert.equal(payload.dispatched, true);
    assert.equal(payload.retryable, false);
    assert.equal(socket.sent.filter((message) => JSON.parse(message).type === "ROTATE_IP").length, 1);
  } finally {
    globalThis.scheduler = previousScheduler;
  }
});

test("durable broker bounds recent terminal correlation and re-acks duplicates", async () => {
  const storage = new MemoryStorage();
  const socket = new FakeSocket({
    kind: "device",
    authenticated: true,
    device_id: "a".repeat(64),
  });
  const control = new DeviceControl(new FakeContext(storage, [socket]), {});

  for (let index = 0; index < MAX_RECENT_OPERATIONS + 5; index += 1) {
    const requestId = `req_${index}`;
    await storage.put("active_operation", {
      request_id: requestId,
      status: "ACCEPTED",
      operation_id: index + 1,
      result: null,
      created_at_ms: index,
      completed_at_ms: null,
    });
    await control.acceptResult(socket, {
      type: "RESULT",
      request_id: requestId,
      result: "UNCHANGED",
      operation_id: index + 1,
    });
  }

  const recent = await storage.get("recent_operations");
  assert.equal(recent.length, MAX_RECENT_OPERATIONS);
  assert.equal(await storage.get("active_operation"), undefined);

  const known = recent[0];
  const sendsBefore = socket.sent.length;
  await control.acceptResult(socket, {
    type: "RESULT",
    request_id: known.request_id,
    result: known.result,
    operation_id: known.operation_id,
  });
  assert.equal(socket.sent.length, sendsBefore + 1);
  assert.equal(socket.closed.length, 0);
});

class MemoryStorage {
  constructor() {
    this.data = new Map();
    this.alarm = null;
  }

  async get(key) {
    return this.data.get(key);
  }

  async put(key, value) {
    this.data.set(key, value);
  }

  async delete(key) {
    this.data.delete(key);
  }

  async getAlarm() {
    return this.alarm;
  }

  async setAlarm(timestamp) {
    this.alarm = timestamp;
  }

  async deleteAlarm() {
    this.alarm = null;
  }
}

class FakeContext {
  constructor(storage, sockets, { autoResponseAtMs = Date.now() } = {}) {
    this.storage = storage;
    this.sockets = sockets;
    this.autoResponsePair = null;
    this.autoResponseTimestamps = new Map();
    if (autoResponseAtMs !== null) {
      for (const socket of sockets) {
        if (socket.attachment?.authenticated === true) {
          this.autoResponseTimestamps.set(socket, new Date(autoResponseAtMs));
        }
      }
    }
  }

  getWebSockets() {
    return this.sockets;
  }

  setWebSocketAutoResponse(pair) {
    this.autoResponsePair = pair;
  }

  getWebSocketAutoResponseTimestamp(socket) {
    return this.autoResponseTimestamps.get(socket) ?? null;
  }

  setAutoResponseTimestamp(socket, atMs) {
    if (atMs === null) {
      this.autoResponseTimestamps.delete(socket);
    } else {
      this.autoResponseTimestamps.set(socket, new Date(atMs));
    }
  }
}

class FakeSocket {
  constructor(attachment, onSend = null) {
    this.attachment = attachment;
    this.onSend = onSend;
    this.sent = [];
    this.closed = [];
  }

  deserializeAttachment() {
    return this.attachment;
  }

  serializeAttachment(attachment) {
    this.attachment = attachment;
  }

  send(message) {
    if (this.onSend) this.onSend(message);
    this.sent.push(message);
  }

  close(code, reason) {
    this.closed.push({ code, reason });
  }
}

function rotateRequest(requestId) {
  return new Request("https://control.internal/manager/rotate-and-wait", {
    method: "POST",
    body: JSON.stringify({ request_id: requestId }),
  });
}

function enrollmentRequest(deviceId, spkiB64) {
  return new Request(`https://control.internal/manager/enroll?device_id=${deviceId}`, {
    method: "PUT",
    body: JSON.stringify({ public_key_spki_b64: spkiB64 }),
  });
}

async function generateIdentity() {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", keyPair.publicKey));
  const spkiB64 = base64Encode(spki);
  return {
    keyPair,
    spkiB64,
    deviceId: await deviceIdFromSpkiB64(spkiB64),
  };
}

async function signAuth(privateKey, deviceId, nonce) {
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    canonicalAuthPayload(deviceId, nonce),
  ));
  return base64UrlEncode(signature);
}

function base64Encode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
