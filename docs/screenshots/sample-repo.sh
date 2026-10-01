#!/bin/zsh
# Builds the sample acme-api repo the Changes screenshot diffs: one commit on a `passkeys` branch,
# plus an uncommitted edit and an untracked test file.
set -e
R=$1; rm -rf $R; mkdir -p $R/src/auth $R/migrations $R/test/auth; cd $R
git init -q -b main; git config user.email dev@example.com; git config user.name dev

cat > src/auth/routes.ts <<'EOF'
import { Router } from "express";
import { login, logout } from "./login";
import { requestReset, confirmReset } from "./reset";

export const auth = Router();

auth.post("/login", login);
auth.post("/logout", logout);
auth.post("/reset", requestReset);
auth.post("/reset/confirm", confirmReset);
EOF
cat > src/auth/session.ts <<'EOF'
import { randomBytes } from "node:crypto";
import { db } from "../db";

export async function createSession(userId: string) {
  const token = randomBytes(32).toString("base64url");
  await db.sessions.insert({ token, userId, createdAt: new Date() });
  return token;
}
EOF
echo "# acme-api" > README.md
git add -A; git commit -qm "Initial auth"

git checkout -qb passkeys
cat > migrations/0042_passkey_credentials.sql <<'EOF'
CREATE TABLE passkey_credentials (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key    BLOB NOT NULL,
  sign_count    INTEGER NOT NULL DEFAULT 0,
  transports    TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at  TIMESTAMP
);

CREATE INDEX passkey_credentials_user ON passkey_credentials(user_id);
EOF
cat > src/auth/passkeys.ts <<'EOF'
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "@simplewebauthn/server";
import { db } from "../db";
import { createSession } from "./session";

const rpID = process.env.RP_ID ?? "localhost";

export async function registerOptions(req, res) {
  const user = req.user;
  const existing = await db.passkeys.forUser(user.id);
  const options = await generateRegistrationOptions({
    rpName: "Acme",
    rpID,
    userName: user.email,
    excludeCredentials: existing.map((c) => ({ id: c.id })),
  });
  req.session.challenge = options.challenge;
  res.json(options);
}

export async function register(req, res) {
  const { verified, registrationInfo } = await verifyRegistrationResponse({
    response: req.body,
    expectedChallenge: req.session.challenge,
    expectedOrigin: `https://${rpID}`,
    expectedRPID: rpID,
  });
  if (!verified) return res.status(400).json({ error: "verification failed" });
  await db.passkeys.insert({ userId: req.user.id, ...registrationInfo.credential });
  res.status(201).end();
}

export async function loginOptions(req, res) {
  const options = await generateAuthenticationOptions({ rpID });
  req.session.challenge = options.challenge;
  res.json(options);
}

export async function login(req, res) {
  const credential = await db.passkeys.find(req.body.id);
  if (!credential) return res.status(401).end();
  const { verified } = await verifyAuthenticationResponse({
    response: req.body,
    expectedChallenge: req.session.challenge,
    expectedOrigin: `https://${rpID}`,
    expectedRPID: rpID,
    credential,
  });
  if (!verified) return res.status(401).end();
  // Same cookie format as password login, so existing sessions stay valid.
  res.cookie("sid", await createSession(credential.userId), { httpOnly: true });
  res.status(200).end();
}
EOF
git add -A; git commit -qm "Add passkey registration and login"

cat > src/auth/routes.ts <<'EOF'
import { Router } from "express";
import { login, logout } from "./login";
import { requestReset, confirmReset } from "./reset";
import * as passkeys from "./passkeys";

export const auth = Router();

auth.post("/login", login);
auth.post("/logout", logout);
auth.post("/reset", requestReset);
auth.post("/reset/confirm", confirmReset);

auth.post("/passkeys/register/options", passkeys.registerOptions);
auth.post("/passkeys/register", passkeys.register);
auth.post("/passkeys/login/options", passkeys.loginOptions);
auth.post("/passkeys/login", passkeys.login);
EOF
cat > test/auth/passkeys.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { app } from "../helpers";

describe("passkeys", () => {
  it("issues registration options with a challenge", async () => {
    const res = await app.asUser("ada").post("/auth/passkeys/register/options");
    expect(res.status).toBe(200);
    expect(res.body.challenge).toBeTruthy();
  });

  it("rejects an unknown credential", async () => {
    const res = await app.post("/auth/passkeys/login").send({ id: "nope" });
    expect(res.status).toBe(401);
  });
});
EOF
