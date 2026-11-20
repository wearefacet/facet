// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { errorMessage } from './util.js';

/** One OAuth session, as stored for a single Facet instance. */
export interface StoredSession {
	access_token: string;
	refresh_token: string;
	/** The OAuth client id the code was exchanged with. Sent on every refresh. */
	client_id: string;
	/** The `iam.Account` id that signed in. */
	account: string;
	/** The role elected on the consent screen. Pinned for the life of the session. */
	role: string;
	/** RFC-3339 UTC instant after which the access token is stale. */
	expires_at: string;
}

/** Where a bearer token came from. `env` tokens are never refreshed. */
export type TokenSource = 'env' | 'session';

export interface ResolvedToken {
	token: string;
	source: TokenSource;
}

/** Raised when the CLI has no usable credentials and the user must sign in again. */
export class AuthError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'AuthError';
	}
}

/**
 * Refresh proactively only when expiry is this close. The server rejects
 * a refresh presented sooner than a short floor after the last one, so the
 * CLI must never refresh eagerly.
 */
const REFRESH_LEEWAY_MS = 60_000;

export function authFilePath(): string {
	const configHome = process.env['XDG_CONFIG_HOME'];
	const base =
		configHome !== undefined && configHome !== '' ? configHome : path.join(os.homedir(), '.config');
	return path.join(base, 'facet', 'auth.json');
}

/** Keys sessions by instance URL, normalizing trailing slashes. */
function instanceKey(instanceUrl: string): string {
	return instanceUrl.replace(/\/+$/, '');
}

export function readSessions(): Record<string, StoredSession> {
	const file = authFilePath();

	let raw: string;
	try {
		raw = readFileSync(file, 'utf8');
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
			return {};
		}
		throw new AuthError(`Cannot read ${file}: ${errorMessage(error)}`);
	}

	let data: unknown;
	try {
		data = JSON.parse(raw);
	} catch (error) {
		throw new AuthError(`${file} is not valid JSON: ${errorMessage(error)}`);
	}
	if (typeof data !== 'object' || data === null || Array.isArray(data)) {
		throw new AuthError(`${file} must hold a JSON object keyed by instance URL.`);
	}
	return data as Record<string, StoredSession>;
}

export function readSession(instanceUrl: string): StoredSession | undefined {
	const session = readSessions()[instanceKey(instanceUrl)];
	if (session === undefined) {
		return undefined;
	}
	if (!isStoredSession(session)) {
		throw new AuthError(
			`The stored session for ${instanceUrl} in ${authFilePath()} is malformed. ` +
				`Run "pnpx @facetapp/cli login" to rewrite it.`
		);
	}
	return session;
}

/** Removes the stored session for one instance. Returns true when one existed. */
export function removeSession(instanceUrl: string): boolean {
	const file = authFilePath();
	const sessions = readSessions();
	if (sessions[instanceKey(instanceUrl)] === undefined) {
		return false;
	}
	delete sessions[instanceKey(instanceUrl)];
	mkdirSync(path.dirname(file), { recursive: true });
	writeFileSync(file, `${JSON.stringify(sessions, null, '\t')}\n`, { mode: 0o600 });
	chmodSync(file, 0o600);
	return true;
}

/** Writes one session while keeping every other stored instance intact. */
export function writeSession(instanceUrl: string, session: StoredSession): void {
	const file = authFilePath();
	mkdirSync(path.dirname(file), { recursive: true });

	const sessions = readSessions();
	sessions[instanceKey(instanceUrl)] = session;

	// The `mode` flag applies only at file creation, so chmod after write
	// keeps the file at 600 even when it already existed with wider access.
	writeFileSync(file, `${JSON.stringify(sessions, null, '\t')}\n`, { mode: 0o600 });
	chmodSync(file, 0o600);
}

/**
 * Resolves the bearer token for one command run. `FACET_TOKEN` wins over
 * stored sessions. A stored session near expiry is refreshed first — never
 * eagerly, because the server enforces a refresh floor.
 */
export async function currentToken(
	instanceUrl: string,
	fetchImpl: typeof fetch = fetch
): Promise<ResolvedToken> {
	const envToken = process.env['FACET_TOKEN'];
	if (envToken !== undefined && envToken !== '') {
		return { token: envToken, source: 'env' };
	}

	const session = readSession(instanceUrl);
	if (session === undefined) {
		throw new AuthError(noSessionMessage(instanceUrl));
	}
	if (isExpiringSoon(session)) {
		const fresh = await refreshSession(instanceUrl, fetchImpl);
		return { token: fresh.access_token, source: 'session' };
	}
	return { token: session.access_token, source: 'session' };
}

export async function refreshSession(
	instanceUrl: string,
	fetchImpl: typeof fetch = fetch
): Promise<StoredSession> {
	const session = readSession(instanceUrl);
	if (session === undefined) {
		throw new AuthError(noSessionMessage(instanceUrl));
	}

	let response: Response;
	try {
		response = await fetchImpl(new URL('/OAuth/token', instanceUrl), {
			method: 'POST',
			headers: { 'content-type': 'application/x-www-form-urlencoded' },
			// The backend binds the refresh token to the client that exchanged
			// the code. A refresh without the client id answers 401.
			body: new URLSearchParams({
				grant_type: 'refresh_token',
				refresh_token: session.refresh_token,
				client_id: session.client_id
			})
		});
	} catch (error) {
		throw new AuthError(refreshFailedMessage(instanceUrl, errorMessage(error)));
	}

	if (!response.ok) {
		throw new AuthError(refreshFailedMessage(instanceUrl, await oauthErrorDetail(response)));
	}

	let payload: unknown;
	try {
		payload = await response.json();
	} catch {
		throw new AuthError(refreshFailedMessage(instanceUrl, 'the token response was not valid JSON'));
	}

	const issued = readTokenPayload(payload, instanceUrl);
	// The refresh grant keeps account and role; only the tokens rotate.
	const fresh: StoredSession = {
		...session,
		access_token: issued.access_token,
		refresh_token: issued.refresh_token,
		expires_at: new Date(Date.now() + issued.expires_in * 1000).toISOString()
	};
	writeSession(instanceUrl, fresh);
	return fresh;
}

export function isExpiringSoon(
	session: StoredSession,
	now: number = Date.now(),
	leewayMs: number = REFRESH_LEEWAY_MS
): boolean {
	const expires = Date.parse(session.expires_at);
	// An unparsable expiry means the token state is unknown — refresh.
	if (Number.isNaN(expires)) {
		return true;
	}
	return expires - now <= leewayMs;
}

function noSessionMessage(instanceUrl: string): string {
	return `No stored session for ${instanceUrl}. Run "pnpx @facetapp/cli login" first.`;
}

function refreshFailedMessage(instanceUrl: string, detail: string): string {
	return (
		`Could not refresh the session for ${instanceUrl} (${detail}). ` +
		`Run "pnpx @facetapp/cli login" to sign in again.`
	);
}

/** Reads the OAuth error name from a failed token response, for the error message. */
async function oauthErrorDetail(response: Response): Promise<string> {
	try {
		const body = (await response.json()) as { error?: unknown };
		if (typeof body.error === 'string' && body.error !== '') {
			return `HTTP ${response.status} ${body.error}`;
		}
	} catch {
		// Fall through to the plain status line.
	}
	return `HTTP ${response.status}`;
}

function readTokenPayload(
	payload: unknown,
	instanceUrl: string
): { access_token: string; refresh_token: string; expires_in: number } {
	if (typeof payload !== 'object' || payload === null) {
		throw new AuthError(
			refreshFailedMessage(instanceUrl, 'the token response was not a JSON object')
		);
	}
	const doc = payload as Record<string, unknown>;
	const access = doc['access_token'];
	const refresh = doc['refresh_token'];
	const expiresIn = doc['expires_in'];
	if (
		typeof access !== 'string' ||
		access === '' ||
		typeof refresh !== 'string' ||
		refresh === ''
	) {
		throw new AuthError(
			refreshFailedMessage(instanceUrl, 'the token response has no access_token or refresh_token')
		);
	}
	if (typeof expiresIn !== 'number' || !Number.isFinite(expiresIn) || expiresIn <= 0) {
		throw new AuthError(
			refreshFailedMessage(instanceUrl, 'the token response has no usable expires_in')
		);
	}
	return { access_token: access, refresh_token: refresh, expires_in: expiresIn };
}

function isStoredSession(value: unknown): value is StoredSession {
	if (typeof value !== 'object' || value === null) {
		return false;
	}
	const doc = value as Record<string, unknown>;
	return (
		typeof doc['access_token'] === 'string' &&
		doc['access_token'] !== '' &&
		typeof doc['refresh_token'] === 'string' &&
		doc['refresh_token'] !== '' &&
		typeof doc['client_id'] === 'string' &&
		doc['client_id'] !== '' &&
		typeof doc['account'] === 'string' &&
		typeof doc['role'] === 'string' &&
		typeof doc['expires_at'] === 'string'
	);
}
