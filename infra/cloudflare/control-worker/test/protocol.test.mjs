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
  await storage.put("public_key_spki_b64", identity.spkiB64);
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
  await storage.put("public_key_spki_b64", identity.spkiB64);

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
  assert.equal(control.authenticatedSocket(), newSocket);
});

test("authenticated reattach re-delivers only the one active dispatched request", async () => {
  const identity = await generateIdentity();
  const nonce = "d".repeat(43);
  const signature = await signAuth(identity.keyPair.privateKey, identity.deviceId, nonce);
  const storage = new MemoryStorage();
  await storage.put("public_key_spki_b64", identity.spkiB64);
  await storage.put("active_operation", {
    request_id: "req_resume",
    status: "DISPATCHED",
    operation_id: null,
    result: null,
    created_at_ms: Date.now(),
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
    ["READY", "ROTATE_IP"],
  );
  assert.equal(JSON.parse(socket.sent[1]).request_id, "req_resume");
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

  let response = await control.rotate(rotateRequest("req_1"));
  assert.equal(response.status, 202);
  assert.equal(socket.sent.length, 1);
  assert.equal(activeWasStoredBeforeSend, true);

  response = await control.rotate(rotateRequest("req_1"));
  assert.equal(response.status, 200);
  assert.equal(socket.sent.length, 1);

  response = await control.rotate(rotateRequest("req_2"));
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error, "BUSY");
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
  assert.equal((await storage.get("recent_operations"))[0].result, "CHANGED");

  response = await control.rotate(rotateRequest("req_1"));
  assert.equal(response.status, 200);
  assert.equal(socket.sent.filter((message) => JSON.parse(message).type === "ROTATE_IP").length, 1);

  const offlineStorage = new MemoryStorage();
  const offline = new DeviceControl(new FakeContext(offlineStorage, []), {});
  response = await offline.rotate(rotateRequest("offline_1"));
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error, "DEVICE_OFFLINE");
  assert.equal(await offlineStorage.get("active_operation"), undefined);
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
}

class FakeContext {
  constructor(storage, sockets) {
    this.storage = storage;
    this.sockets = sockets;
  }

  getWebSockets() {
    return this.sockets;
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
  return new Request("https://control.internal/manager/rotate", {
    method: "POST",
    body: JSON.stringify({ request_id: requestId }),
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
