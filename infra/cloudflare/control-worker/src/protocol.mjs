export const PROTOCOL_VERSION = 1;
export const AUTH_DOMAIN = "MISH_CONTROL_AUTH_V1";
export const MAX_REQUEST_ID_BYTES = 64;
export const MAX_BODY_BYTES = 4096;
export const MAX_RECENT_OPERATIONS = 32;
export const DEVICE_AUTH_CHALLENGE_MAX_AGE_MS = 60_000;
export const RESULT_CODES = new Set(["CHANGED", "UNCHANGED", "FAILED", "REJECTED"]);

const REQUEST_ID = /^[A-Za-z0-9_-]{1,64}$/;
const DEVICE_ID = /^[0-9a-f]{64}$/;
const B64URL_32 = /^[A-Za-z0-9_-]{43}$/;
const B64URL_SIG = /^[A-Za-z0-9_-]{86}$/;

export function isDeviceId(value) {
  return typeof value === "string" && DEVICE_ID.test(value);
}

export function isRequestId(value) {
  return typeof value === "string" &&
    new TextEncoder().encode(value).length <= MAX_REQUEST_ID_BYTES &&
    REQUEST_ID.test(value);
}

export function isFreshAuthChallenge(issuedAtMs, nowMs = Date.now()) {
  return Number.isSafeInteger(issuedAtMs) &&
    Number.isSafeInteger(nowMs) &&
    issuedAtMs <= nowMs &&
    nowMs - issuedAtMs <= DEVICE_AUTH_CHALLENGE_MAX_AGE_MS;
}

export function challengeMessage(nonce) {
  if (!B64URL_32.test(nonce)) throw new Error("invalid nonce");
  return JSON.stringify({ type: "CHALLENGE", v: PROTOCOL_VERSION, nonce });
}

export function readyMessage() {
  return JSON.stringify({ type: "READY", v: PROTOCOL_VERSION });
}

export function rotateMessage(requestId) {
  if (!isRequestId(requestId)) throw new Error("invalid request id");
  return JSON.stringify({ type: "ROTATE_IP", v: PROTOCOL_VERSION, request_id: requestId });
}

export function resultAckMessage(requestId) {
  if (!isRequestId(requestId)) throw new Error("invalid request id");
  return JSON.stringify({ type: "RESULT_ACK", v: PROTOCOL_VERSION, request_id: requestId });
}

export function canonicalAuthPayload(deviceId, nonce) {
  if (!isDeviceId(deviceId) || !B64URL_32.test(nonce)) throw new Error("invalid auth input");
  return new TextEncoder().encode(`${AUTH_DOMAIN}\n${deviceId}\n${nonce}`);
}

export function parseDeviceMessage(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 2048 || raw.trim() !== raw) {
    throw new Error("invalid device message");
  }
  const value = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value) || value.v !== PROTOCOL_VERSION) {
    throw new Error("invalid device message");
  }

  if (value.type === "AUTH") {
    requireExactKeys(value, ["v", "type", "device_id", "signature"]);
    if (!isDeviceId(value.device_id) || typeof value.signature !== "string" ||
        !B64URL_SIG.test(value.signature)) {
      throw new Error("invalid auth");
    }
    return value;
  }

  if (value.type === "ACCEPTED") {
    requireExactKeys(value, ["v", "type", "request_id", "operation_id"]);
    if (!isRequestId(value.request_id) ||
        !Number.isSafeInteger(value.operation_id) || value.operation_id <= 0) {
      throw new Error("invalid accepted");
    }
    return value;
  }

  if (value.type === "RESULT") {
    const allowed = ["v", "type", "request_id", "result", "operation_id"];
    requireAllowedKeys(value, allowed);
    for (const key of ["v", "type", "request_id", "result"]) {
      if (!(key in value)) throw new Error("invalid result");
    }
    if (!isRequestId(value.request_id) || !RESULT_CODES.has(value.result)) {
      throw new Error("invalid result");
    }
    if (value.operation_id !== undefined &&
        (!Number.isSafeInteger(value.operation_id) || value.operation_id <= 0)) {
      throw new Error("invalid operation id");
    }
    if (value.result !== "REJECTED" && value.operation_id === undefined) {
      throw new Error("terminal result requires operation id");
    }
    return value;
  }

  throw new Error("unsupported device message");
}

export function parseManagerRotateBody(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid rotate body");
  }
  requireExactKeys(value, ["request_id"]);
  if (!isRequestId(value.request_id)) throw new Error("invalid request id");
  return { request_id: value.request_id };
}

export function parseEnrollmentBody(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid enrollment body");
  }
  requireExactKeys(value, ["public_key_spki_b64"]);
  if (typeof value.public_key_spki_b64 !== "string" ||
      value.public_key_spki_b64.length < 80 || value.public_key_spki_b64.length > 700 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(value.public_key_spki_b64)) {
    throw new Error("invalid public key");
  }
  return { public_key_spki_b64: value.public_key_spki_b64 };
}

export function randomNonce() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export function base64UrlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export function base64UrlDecode(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw new Error("invalid base64url");
  }
  const padded = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function base64Decode(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export async function deviceIdFromSpkiB64(value) {
  const bytes = base64Decode(value);
  if (bytes.length === 0 || bytes.length > 512) throw new Error("invalid SPKI");
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...hash].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifyDeviceSignature(spkiB64, signatureB64Url, payload) {
  const key = await crypto.subtle.importKey(
    "spki",
    base64Decode(spkiB64),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    base64UrlDecode(signatureB64Url),
    payload,
  );
}

export async function managerAuthorized(request, expectedToken) {
  if (typeof expectedToken !== "string" || expectedToken.length < 32) return false;
  const prefix = "Bearer ";
  const raw = request.headers.get("Authorization") || "";
  if (!raw.startsWith(prefix)) return false;
  const supplied = raw.slice(prefix.length);
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(expectedToken)),
  ]);
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  let diff = a.length ^ b.length;
  for (let index = 0; index < Math.min(a.length, b.length); index += 1) diff |= a[index] ^ b[index];
  return diff === 0;
}

export async function readBoundedJson(request) {
  const text = await request.text();
  if (text.length === 0 || text.length > MAX_BODY_BYTES) throw new Error("invalid body size");
  return JSON.parse(text);
}

function requireExactKeys(value, keys) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length ||
      actual.some((key, index) => key !== expected[index])) {
    throw new Error("unexpected fields");
  }
}

function requireAllowedKeys(value, keys) {
  const allowed = new Set(keys);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new Error("unexpected fields");
  }
}
