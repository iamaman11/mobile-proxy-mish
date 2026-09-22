import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalAuthPayload,
  challengeMessage,
  isDeviceId,
  isRequestId,
  parseDeviceMessage,
  parseEnrollmentBody,
  parseManagerRotateBody,
  readyMessage,
  resultAckMessage,
  rotateMessage,
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
