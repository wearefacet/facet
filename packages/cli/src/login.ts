// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import http from 'node:http';
import { ApiError, requestJson } from './api.js';
import { writeSession, type StoredSession } from './auth.js';
import { errorMessage } from './util.js';

/** Raised when the sign-in flow cannot complete. */
export class LoginError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'LoginError';
	}
}

/** The CLI's first-party app registration slug. */
export const CLI_SLUG = 'facet-cli';

/** How long the CLI waits for the browser round-trip before giving up. */
const LOGIN_TIMEOUT_MS = 5 * 60_000;

export interface ClientInfo {
	slug: string;
	client_id: string;
	name: string;
	client_type: string;
}

/**
 * Resolves the `facet-cli` registration on one instance. Every failure path
 * of the endpoint returns the same 404, so the error cannot disclose
 * whether a draft registration exists.
 */
export async function resolveClientInfo(
	instanceUrl: string,
	fetchImpl: typeof fetch = fetch
): Promise<ClientInfo> {
	const query = new URLSearchParams({ slug: CLI_SLUG });
	const info = await requestJson<ClientInfo>(
		instanceUrl,
		`/OAuth/client-info?${query.toString()}`,
		{
			fetchImpl
		}
	).catch((error) => {
		if (error instanceof ApiError && error.status === 404) {
			throw new LoginError(`No active "${CLI_SLUG}" app registration found on ${instanceUrl}.`);
		}
		throw error;
	});
	if (typeof info?.client_id !== 'string' || info.client_id === '') {
		throw new LoginError(`${instanceUrl} returned a client-info body without a client_id.`);
	}
	return info;
}

/** The S256 challenge for one verifier: base64url(SHA-256(verifier)). */
export function challengeFor(verifier: string): string {
	return createHash('sha256').update(verifier).digest('base64url');
}

/** A fresh PKCE pair: a 43-character verifier and its S256 challenge. */
export function createPkcePair(): { code_verifier: string; code_challenge: string } {
	const code_verifier = randomBytes(32).toString('base64url');
	return { code_verifier, code_challenge: challengeFor(code_verifier) };
}

export interface AuthorizeParams {
	clientId: string;
	redirectUri: string;
	codeChallenge: string;
	state: string;
}

/** Builds the authorize URL the browser opens for the consent screen. */
export function buildAuthorizeUrl(instanceUrl: string, params: AuthorizeParams): string {
	const url = new URL('/OAuth/authorize', instanceUrl);
	url.searchParams.set('response_type', 'code');
	url.searchParams.set('client_id', params.clientId);
	url.searchParams.set('redirect_uri', params.redirectUri);
	url.searchParams.set('code_challenge', params.codeChallenge);
	url.searchParams.set('code_challenge_method', 'S256');
	url.searchParams.set('state', params.state);
	return url.toString();
}

/** What the instance delivered back to the loopback server. */
export interface CallbackResult {
	code?: string;
	state?: string;
	error?: string;
	error_description?: string;
}

export interface CallbackHandle {
	/** The `redirect_uri` presented at authorize and token time. */
	redirectUri: string;
	waitForCallback(): Promise<CallbackResult>;
	close(): void;
}

/**
 * Starts a one-shot callback server on an ephemeral loopback port. Bound to
 * `127.0.0.1` (not the `localhost` name) so the browser cannot resolve to
 * IPv6 and miss a single-stack listener.
 */
export function startCallbackServer(): Promise<CallbackHandle> {
	return new Promise((resolveServer) => {
		let deliver: ((result: CallbackResult) => void) | undefined;
		// A callback may land before the caller starts listening — keep it.
		let buffered: CallbackResult | undefined;
		let timer: NodeJS.Timeout | undefined;

		const server = http.createServer((request, response) => {
			const url = new URL(request.url ?? '/', 'http://127.0.0.1');
			if (url.pathname !== '/callback') {
				response.writeHead(404);
				response.end();
				return;
			}
			clearTimeout(timer);
			const result: CallbackResult = {
				code: url.searchParams.get('code') ?? undefined,
				state: url.searchParams.get('state') ?? undefined,
				error: url.searchParams.get('error') ?? undefined,
				error_description: url.searchParams.get('error_description') ?? undefined
			};
			response.writeHead(200, { 'content-type': 'text/html' });
			response.end(
				'<!doctype html><title>Facet CLI</title>' +
					'<p>Sign-in complete. You can close this window.</p>'
			);
			const pending = deliver;
			if (pending !== undefined) {
				deliver = undefined;
				pending(result);
			} else {
				buffered = result;
			}
		});

		server.listen(0, '127.0.0.1', () => {
			const address = server.address();
			const port = typeof address === 'object' && address !== null ? address.port : 0;
			resolveServer({
				redirectUri: `http://127.0.0.1:${port}/callback`,
				waitForCallback: () =>
					new Promise<CallbackResult>((resolve, reject) => {
						if (buffered !== undefined) {
							resolve(buffered);
							return;
						}
						deliver = resolve;
						timer = setTimeout(() => {
							deliver = undefined;
							reject(
								new LoginError(
									'Timed out waiting for the browser sign-in. Open the authorize URL in a browser that can reach the instance, then start again.'
								)
							);
						}, LOGIN_TIMEOUT_MS);
					}),
				close: () => {
					clearTimeout(timer);
					deliver = undefined;
					// Drop keep-alive sockets so the process never lingers.
					server.closeAllConnections();
					server.close();
				}
			});
		});
	});
}

export interface TokenIssuance {
	access_token: string;
	refresh_token: string;
	expires_in: number;
}

/** Exchanges the authorization code for tokens with the PKCE verifier. */
export async function exchangeCode(
	instanceUrl: string,
	params: { code: string; redirectUri: string; clientId: string; codeVerifier: string },
	fetchImpl: typeof fetch = fetch
): Promise<TokenIssuance> {
	const body = new URLSearchParams({
		grant_type: 'authorization_code',
		code: params.code,
		redirect_uri: params.redirectUri,
		client_id: params.clientId,
		code_verifier: params.codeVerifier
	});

	let response: Response;
	try {
		response = await fetchImpl(new URL('/OAuth/token', instanceUrl), {
			method: 'POST',
			headers: { 'content-type': 'application/x-www-form-urlencoded' },
			body
		});
	} catch (error) {
		throw new LoginError(
			`Cannot reach ${instanceUrl} to exchange the code: ${errorMessage(error)}`
		);
	}
	if (!response.ok) {
		throw new LoginError(await oauthFailure(response));
	}

	const payload = (await response.json().catch(() => null)) as Partial<TokenIssuance> | null;
	if (
		payload === null ||
		typeof payload.access_token !== 'string' ||
		payload.access_token === '' ||
		typeof payload.refresh_token !== 'string' ||
		payload.refresh_token === '' ||
		typeof payload.expires_in !== 'number' ||
		payload.expires_in <= 0
	) {
		throw new LoginError('The token endpoint returned an unusable response.');
	}
	return {
		access_token: payload.access_token,
		refresh_token: payload.refresh_token,
		expires_in: payload.expires_in
	};
}

/** Reads the OAuth error name out of a failed token response. */
async function oauthFailure(response: Response): Promise<string> {
	let detail = `HTTP ${response.status}`;
	try {
		const body = (await response.json()) as { error?: unknown; error_description?: unknown };
		if (typeof body.error === 'string' && body.error !== '') {
			detail = body.error;
			if (typeof body.error_description === 'string' && body.error_description !== '') {
				detail += `: ${body.error_description}`;
			}
		}
	} catch {
		// Keep the plain status line.
	}
	return `The token exchange failed (${detail}).`;
}

interface MeResponse {
	account: { id: string };
	active_role: string;
}

/** The one validation read: proves the token and yields account + role. */
async function readMe(
	instanceUrl: string,
	token: string,
	fetchImpl: typeof fetch
): Promise<MeResponse> {
	const me = await requestJson<MeResponse>(instanceUrl, '/Api/iam/me', { token, fetchImpl }).catch(
		(error) => {
			throw new LoginError(
				`The new session failed its validation read on ${instanceUrl}: ${errorMessage(error)}`
			);
		}
	);
	if (
		typeof me?.account?.id !== 'string' ||
		me.account.id === '' ||
		typeof me.active_role !== 'string' ||
		me.active_role === ''
	) {
		throw new LoginError('The instance did not return a usable session profile.');
	}
	return me;
}

/** Opens the platform browser. Fails only when no helper exists at all. */
async function openBrowser(url: string): Promise<void> {
	const platform = process.platform;
	const command = platform === 'darwin' ? 'open' : platform === 'win32' ? 'cmd' : 'xdg-open';
	const args = platform === 'win32' ? ['/c', 'start', '', url] : [url];
	await new Promise<void>((resolve, reject) => {
		const child = spawn(command, args, { stdio: 'ignore', detached: true });
		child.on('error', reject);
		child.on('spawn', () => {
			child.unref();
			resolve();
		});
	});
}

export interface LoginOptions {
	instanceUrl: string;
	fetchImpl?: typeof fetch;
	openBrowser?: (url: string) => Promise<void>;
	startServer?: () => Promise<CallbackHandle>;
}

/**
 * Runs the full loopback sign-in flow: client-info, PKCE, authorize URL,
 * browser round-trip, state check, token exchange, one validation read,
 * and stores the session for the instance.
 */
export async function login(options: LoginOptions): Promise<StoredSession> {
	const instanceUrl = options.instanceUrl;
	const fetchImpl = options.fetchImpl ?? fetch;

	const client = await resolveClientInfo(instanceUrl, fetchImpl);
	const { code_verifier, code_challenge } = createPkcePair();
	const state = randomBytes(16).toString('base64url');

	const server = await (options.startServer ?? startCallbackServer)();
	const authorizeUrl = buildAuthorizeUrl(instanceUrl, {
		clientId: client.client_id,
		redirectUri: server.redirectUri,
		codeChallenge: code_challenge,
		state
	});

	try {
		// Listen before the browser opens — a fast callback must not be lost.
		const callbackPromise = server.waitForCallback();
		// B-179: the URL is printed on every run. On a headless host the
		// opener may exist yet open nothing, so the URL on stderr is the
		// only door to sign in through — the wait must never be silent.
		console.error(`If the browser did not open, sign in through this URL:\n${authorizeUrl}`);
		try {
			await (options.openBrowser ?? openBrowser)(authorizeUrl);
		} catch {
			// A missing or broken browser helper must not block sign-in.
			console.error('Cannot open a browser automatically.');
		}

		const callback = await callbackPromise;
		if (callback.error !== undefined) {
			const detail = callback.error_description ? ` (${callback.error_description})` : '';
			throw new LoginError(`Authorization failed: ${callback.error}${detail}`);
		}
		if (callback.state !== state) {
			throw new LoginError('The sign-in callback carried a state that does not match the request.');
		}
		if (callback.code === undefined || callback.code === '') {
			throw new LoginError('The sign-in callback carried no authorization code.');
		}

		const issued = await exchangeCode(
			instanceUrl,
			{
				code: callback.code,
				redirectUri: server.redirectUri,
				clientId: client.client_id,
				codeVerifier: code_verifier
			},
			fetchImpl
		);

		const me = await readMe(instanceUrl, issued.access_token, fetchImpl);
		const session: StoredSession = {
			access_token: issued.access_token,
			refresh_token: issued.refresh_token,
			client_id: client.client_id,
			account: me.account.id,
			role: me.active_role,
			expires_at: new Date(Date.now() + issued.expires_in * 1000).toISOString()
		};
		writeSession(instanceUrl, session);
		return session;
	} finally {
		server.close();
	}
}
