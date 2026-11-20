// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * SSR Set-Cookie forwarding for the proxied backend namespaces.
 *
 * SvelteKit propagates `Set-Cookie` back to the browser only for same-origin
 * `event.fetch` calls. `handleFetch` in `hooks.server.ts` rewrites `/Api/*`
 * and `/OAuth/*` to the plain-HTTP backend address (`BACKEND_URL`) — a
 * cross-origin URL — so any cookie the backend sends on those responses is
 * dropped. That singled out `POST /Api/iam/refresh`: its whole job is to
 * rotate the `auth_token` / `refresh_token` cookies, so a rotation performed
 * during SSR never reached the browser cookie jar and the next browser-side
 * refresh presented a stale token, which the backend's reuse detection answers
 * by revoking the session (`401 "Session revoked due to token reuse"`).
 *
 * `applySetCookies` is called on every rewritten response. It parses each
 * `Set-Cookie` header and re-issues the cookie through `event.cookies.set`,
 * SvelteKit's supported channel for attaching cookies to the SSR page
 * response. Cookies applied here are also visible to later same-event
 * sub-requests, so a token rotated by `handleAuth` reaches the layout loads
 * that follow it in the same request.
 *
 * The parser lives in this project because the cookie universe is fully
 * owned by the backend (`IAM::TokenEmitter.set_cookies` and the logout
 * cleanup): JWTs and hex tokens with `Path`, `Secure`, `HttpOnly`,
 * `SameSite=Lax`, plus the logout expiry cookie. Adding a library for four
 * fixed attributes would outweigh the parsing risk.
 */

/** The cookie-writing surface of a SvelteKit `RequestEvent`, narrowed for tests. */
export interface CookieSetter {
	cookies: {
		set: (
			name: string,
			value: string,
			options: {
				path: string;
				domain?: string;
				secure?: boolean;
				httpOnly?: boolean;
				sameSite?: 'strict' | 'lax' | 'none';
				maxAge?: number;
				expires?: Date;
			}
		) => void;
	};
}

export interface ParsedCookie {
	name: string;
	value: string;
	path?: string;
	domain?: string;
	secure?: boolean;
	httpOnly?: boolean;
	sameSite?: 'strict' | 'lax' | 'none';
	maxAge?: number;
	expires?: Date;
}

/**
 * Parses one `Set-Cookie` header string. Returns `null` for a header without
 * a usable `name=value` prefix. Unknown or malformed attributes are ignored;
 * the emitting side is this project's backend, which only ever sends the
 * attributes handled here.
 */
export function parseSetCookie(header: string): ParsedCookie | null {
	const [nameValue, ...rawAttributes] = header.split(';');
	const attributes = rawAttributes.map((s) => s.trim());
	const eq = nameValue.indexOf('=');
	if (eq <= 0) return null;
	const name = nameValue.slice(0, eq).trim();
	const value = nameValue.slice(eq + 1).trim();
	if (!name) return null;

	const parsed: ParsedCookie = { name, value };

	for (const attribute of attributes) {
		const [key, val] = attribute.split('=').map((p) => p.trim());
		switch (key.toLowerCase()) {
			case 'path':
				parsed.path = val || '/';
				break;
			case 'domain':
				parsed.domain = val;
				break;
			case 'secure':
				parsed.secure = true;
				break;
			case 'httponly':
				parsed.httpOnly = true;
				break;
			case 'samesite': {
				const mode = val?.toLowerCase();
				if (mode === 'strict' || mode === 'lax' || mode === 'none') {
					parsed.sameSite = mode;
				}
				break;
			}
			case 'max-age': {
				const seconds = Number.parseInt(val, 10);
				if (!Number.isNaN(seconds)) parsed.maxAge = seconds;
				break;
			}
			case 'expires':
				parsed.expires = new Date(val ?? '');
				break;
		}
	}

	return parsed;
}

/**
 * Reads every `Set-Cookie` header of a backend response and applies each
 * cookie to SvelteKit's event cookie jar. Returns the number of applied
 * cookies (0 is normal — most responses carry none).
 */
export function applySetCookies(event: CookieSetter, response: Response): number {
	const raw =
		typeof response.headers.getSetCookie === 'function'
			? response.headers.getSetCookie()
			: headerList(response.headers.get('set-cookie'));
	let applied = 0;

	for (const header of raw) {
		const parsed = parseSetCookie(header);
		if (!parsed) continue;
		event.cookies.set(parsed.name, parsed.value, {
			path: parsed.path ?? '/',
			domain: parsed.domain,
			secure: parsed.secure,
			httpOnly: parsed.httpOnly,
			sameSite: parsed.sameSite ?? 'lax',
			maxAge: parsed.maxAge,
			expires: parsed.expires
		});
		applied++;
	}

	return applied;
}

/**
 * Fallback for runtimes without `Headers.getSetCookie`: splits a combined
 * header value back into single-cookie strings. `Expires` values contain a
 * comma, so a plain `, ` split would cut them apart.
 */
function headerList(setCookie: string | null): string[] {
	if (!setCookie) return [];
	const out: string[] = [];
	let start = 0;
	for (let i = 0; i < setCookie.length; i++) {
		if (setCookie[i] !== ',') continue;
		// A comma is a separator only when it precedes a token terminator
		// (`=` or `;`) before the next `;`, i.e. it opens a new `name=`.
		let j = i + 1;
		while (j < setCookie.length && setCookie[j] !== ';' && setCookie[j] !== '=') j++;
		if (j < setCookie.length && setCookie[j] === '=') {
			out.push(setCookie.slice(start, i).trim());
			start = i + 1;
		}
	}
	out.push(setCookie.slice(start).trim());
	return out.filter((s) => s.length > 0);
}
