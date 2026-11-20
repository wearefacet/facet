// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, expect, type APIRequestContext, type Page } from '@playwright/test';

/**
 * App head to toe: one serial file that registers an
 * app through the Configure wizard, deploys a build with the facet CLI, sees
 * it served at its own host, drives the OAuth (PKCE + DPoP) round trip from
 * the served origin — ending in a real CRM read with the app token — then
 * opens the app assistant (the @facetapp/chat package bundle): the package
 * window displays, the disabled app denies the conversation create, the
 * settings tab enables the assistant, and a conversation is created through
 * the package against the live stack. The scenario never streams a turn —
 * the stack config points the assistant provider at a dead stub (harness
 * decision D11) — the roll back to the first revision through the CLI ends
 * the file.
 *
 * Phase order is state-accumulating on purpose: register → deploy → serve →
 * OAuth/DPoP → assistant → rollback. The browser context carries the admin
 * `storageState` from the setup project. Facet session cookies are host-only,
 * so the app origin never sees them: the OAuth bounce to facet.localhost
 * re-attaches the session inside the consent surface, and the app receives
 * only its own DPoP-bound JWT.
 */

// ── Constants ──────────────────────────────────────────────────────────────

// The two vhost origins of the stack. Playwright's browser gets
// `--host-resolver-rules`; every other client resolves facet.localhost and
// app.apps.localhost through the compose network aliases.
const APP_ORIGIN = 'https://app.apps.localhost:3443';
const APP_URL = `${APP_ORIGIN}/`;
const UNKNOWN_HOST_URL = 'https://cold.apps.localhost:3443/';
const FACET_ORIGIN = 'https://facet.localhost:3443';
const COMPANY_LIST_PATH = '/Api/crm/Company';

// The app under test. The slug is also the CLI's `facet.config.json` app id.
const APP_DISPLAY_NAME = 'CrudWorks Portal';
const APP_SLUG = 'crudworks';
const APP_HOST = 'app.apps.localhost';
const APP_REDIRECT_URI = `${APP_ORIGIN}/oauth/callback`;
const APP_ORIGIN_ALLOWED = APP_ORIGIN;

// The assistant window title the fixture configures; the package UI copy the
// assertions match (the package ships plain-English strings, not test ids).
const ASSISTANT_NAME = 'CrudWorks Assistant';

// The fresh company the scenario arranges for the app-token read.
const COMPANY_NAME = 'CrudWorks AB';

// Location of the static mini-app inside the runner image (COPY e2e/fixtures).
const MiniappSourceDir = path.join(
	path.dirname(fileURLToPath(import.meta.url)),
	'..',
	'fixtures',
	'miniapp'
);

/** Escapes a literal for use inside `new RegExp`. */
function escapeRegExp(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * The CSRF surface for scripted JSON writes: the `X-Requested-With` header
 * (`HTTP::Helpers.require_csrf`), not cookies or tokens.
 */
const CSRF_HEADERS = { 'X-Requested-With': 'XMLHttpRequest' };

/** Hard ceiling for one CLI invocation — a stalled fetch must not wedge the file. */
const CLI_TIMEOUT_MS = 120_000;

/** The marker comment baked into every served build, keyed by revision. The
 * serving assertions match on it to prove which build the host streams. */
function revisionMarker(revision: number): string {
	return `<!-- facet-e2e-revision:${revision} -->`;
}

/** Rewrites the build input: the fixture with the baked client id and API
 * origin, plus the revision marker comment — and the chat-package browser
 * bundle the runner image dropped next to the fixture (every deployed
 * revision carries it; the fixture mounts the assistant when a session
 * exists). Overwriting one folder between deploys mirrors a real rebuild —
 * the CLI config never changes. */
function writeMiniappBuild(buildDir: string, clientId: string, revision: number): void {
	const fixture = readFileSync(path.join(MiniappSourceDir, 'index.html'), 'utf8');
	writeFileSync(
		path.join(buildDir, 'index.html'),
		fixture.replace('__FACET_CLIENT_ID__', clientId).replaceAll('__FACET_ORIGIN__', FACET_ORIGIN) +
			`\n${revisionMarker(revision)}`
	);
	copyFileSync(
		path.join(MiniappSourceDir, 'facet-assistant.js'),
		path.join(buildDir, 'facet-assistant.js')
	);
}

/** Reads the served build through a cookie-free context and asserts which
 * revision the host streams. Serving reads `active_deployment` fresh from
 * the database on every request, so the flip lands on the first read after
 * the PATCH commits. */
async function expectServedRevision(client: APIRequestContext, revision: number): Promise<void> {
	const response = await client.get('/');
	expect(response.status(), 'the artifact stream must answer 200').toBe(200);
	const body = await response.text();
	const expected = revisionMarker(revision);
	const other = revisionMarker(revision === 1 ? 2 : 1);
	expect(body, `the served build must carry ${expected}`).toContain(expected);
	expect(body, `the served build must not carry ${other}`).not.toContain(other);
}

/** Runs one facet-cli command with the given env, asserting exit 0. */
function runCli(args: string[], opts: { cwd: string; env: Record<string, string> }) {
	const result = spawnSync(process.execPath, ['/cli/dist/index.js', ...args], {
		cwd: opts.cwd,
		env: { ...process.env, ...opts.env },
		encoding: 'utf8',
		timeout: CLI_TIMEOUT_MS,
		maxBuffer: 16 * 1024 * 1024
	});
	expect(result.error, `facet-cli ${args.join(' ')} crashed`).toBeUndefined();
	const outcome =
		result.status === null
			? `killed (${result.signal}) after ${CLI_TIMEOUT_MS / 1000}s`
			: `exit ${result.status}`;
	expect(
		result.status,
		`facet-cli ${args.join(' ')} failed (${outcome}):\n${result.stdout}\n${result.stderr}`
	).toBe(0);
	return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

// ── Helpers over the Playwright request fixture (facet.localhost) ──────────

async function loginToken(request: APIRequestContext): Promise<string> {
	const response = await request.post('/Api/iam/login', {
		headers: CSRF_HEADERS,
		data: { email: 'admin@example.tld', password: 'admin', cookie: false }
	});
	expect(response.status(), 'the scripted admin login must succeed').toBe(200);
	const body = await response.json();
	expect(body.token, 'the login probe must return a bearer token').toBeTruthy();
	return body.token as string;
}

/** Reads one `app.App` content field through the admin API. */
async function appField(
	request: APIRequestContext,
	appId: string,
	field: string
): Promise<unknown> {
	const response = await request.get(`/Api/app/App/${appId}`);
	expect(response.status()).toBe(200);
	const body = await response.json();
	return body.data?.[field];
}

/** Patches one `app.App` field and asserts the write landed. */
async function patchAppField(
	request: APIRequestContext,
	appId: string,
	field: string,
	value: unknown
): Promise<void> {
	const response = await request.patch(`/Api/app/App/${appId}`, {
		headers: CSRF_HEADERS,
		data: { [field]: value }
	});
	expect(response.status(), `patching ${field} must succeed`).toBe(200);
}

/** The DPoP material the callback page persists for the runner-side probes. */
interface BoundSession {
	access_token: string;
	jwk: { kty: string; crv: string; x: string; y: string };
	jkt: string;
	privateJwk: JsonWebKey;
}

function readBoundSession(page: Page): Promise<BoundSession> {
	return page.evaluate(() => {
		const pub = JSON.parse(sessionStorage.getItem('crudworks.dpop.pub') ?? 'null');
		const priv = JSON.parse(sessionStorage.getItem('crudworks.dpop.priv') ?? 'null');
		return {
			access_token: sessionStorage.getItem('crudworks.token') ?? '',
			jwk: pub?.jwk?.kty ? pub.jwk : null,
			jkt: pub?.jkt ?? '',
			privateJwk: priv
		};
	});
}

// ── WebCrypto (runner-side DPoP probe helpers) ─────────────────────────────

/** base64url without padding over a byte array. */
function b64url(bytes: Uint8Array): string {
	let bin = '';
	for (const byte of bytes) bin += String.fromCharCode(byte);
	return Buffer.from(bin, 'binary').toString('base64url');
}

async function sha256B64url(text: string): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
	return b64url(new Uint8Array(digest));
}

/**
 * Signs a DPoP proof with the key material the browser page used. Node's
 * WebCrypto emits the raw R‖S ES256 signatures RFC 9449 clients send, so the
 * positive control also proves the server accepts third-party JOSE signature
 * encodings, not only the browser's.
 */
async function signedProof(
	session: BoundSession,
	htm: string,
	htu: string,
	ath?: string
): Promise<string> {
	const privateKey = await crypto.subtle.importKey(
		'jwk',
		session.privateJwk,
		{ name: 'ECDSA', namedCurve: 'P-256' },
		false,
		['sign']
	);
	const header = { alg: 'ES256', typ: 'dpop+jwt', jwk: session.jwk };
	const payload: Record<string, unknown> = {
		jti: crypto.randomUUID(),
		htm,
		htu,
		iat: Math.floor(Date.now() / 1000)
	};
	if (ath !== undefined) payload.ath = ath;

	const encoder = new TextEncoder();
	const signingInput = `${b64url(encoder.encode(JSON.stringify(header)))}.${b64url(encoder.encode(JSON.stringify(payload)))}`;
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		privateKey,
		encoder.encode(signingInput)
	);
	return `${signingInput}.${b64url(new Uint8Array(signature))}`;
}

/**
 * Logs each phase to the runner's stdout with a timestamp before running it:
 * the list reporter stays silent until a test finishes, so a long phase must
 * say its name or a slow run is indistinguishable from a hang.
 */
async function phase(name: string, body: () => Promise<void>): Promise<void> {
	console.log(`\n[${new Date().toISOString().slice(11, 19)}] >> ${name}`);
	await test.step(name, body);
}

// ── The scenario ───────────────────────────────────────────────────────────

test('app head to toe: register, deploy, serve, OAuth DPoP', async ({
	page,
	request,
	context,
	playwright
}) => {
	test.setTimeout(10 * 60_000);

	let facetToken = '';
	let appId = '';
	let clientId = '';

	// One build folder + one CLI workspace for the whole file: the rollback
	// section rebuilds INTO the same folder, like a real user would.
	const cliBuildDir = mkdtempSync(path.join(tmpdir(), 'crudworks-build-'));
	const cliWorkspace = mkdtempSync(path.join(tmpdir(), 'crudworks-workspace-'));

	// ── 0. Bootstrap ────────────────────────────────────────────────────
	await phase('scripted admin login mints the CLI token', async () => {
		facetToken = await loginToken(request);
	});

	// ── 1. Register through the wizard ──────────────────────────────────
	await phase('wizard: setup writes identity, origins and redirect', async () => {
		// The bare /new entry redirect the "New app" button drives;
		// client_type defaults to public (PKCE + DPoP).
		await page.goto('/Configure/apps/new');
		await expect(page).toHaveURL(/\/Configure\/apps\/new\/setup$/);

		await page.getByLabel('Display name').fill(APP_DISPLAY_NAME);
		// The slug auto-derives from the display name; pin it explicitly so
		// the CLI's facet.config.json app id is deterministic.
		await page.getByRole('button', { name: 'Edit', exact: true }).click();
		await page.getByLabel('Slug', { exact: true }).fill(APP_SLUG);
		await page.getByLabel('Description').fill('E2E mini-app for the head-to-toe gate.');

		const origins = page.getByLabel('Allowed origins', { exact: true });
		await origins.fill(APP_ORIGIN_ALLOWED);
		await origins.press('Enter');

		const redirects = page.getByLabel('Redirect URIs', { exact: true });
		await redirects.fill(APP_REDIRECT_URI);
		await redirects.press('Enter');

		// The per-URI origin match asserts the allowed-origins list held.
		await expect(page.getByText('Matches an allowed origin.')).toBeVisible();

		await page.getByRole('button', { name: 'Continue' }).click();
		await expect(page).toHaveURL(/\/Configure\/apps\/new\/permissions\?app=/);
	});

	await phase('wizard: grants editor gives crm.Company write', async () => {
		// The grants rail is domain-keyed; the CRM bundle seeds the crm domain.
		await page.getByRole('tab', { name: 'crm', exact: true }).click();
		// Anchor the card on its level group's accessible name: a text filter
		// is fragile here (hasText 'Company' substring-matches the Activity,
		// Contact and Prospect descriptions; a regex hasText runs on the raw
		// textContent, which Svelte pads with the template's newlines). The
		// group name is exact so the CompanyMembership child group inside the
		// same card cannot swallow the match.
		const card = page.locator('.grants-card').filter({
			has: page.getByRole('group', { name: 'Access level for Company', exact: true })
		});
		await expect(card).toBeVisible();
		const levelGroup = card.getByRole('group', { name: 'Access level for Company', exact: true });
		await levelGroup.getByRole('button', { name: 'Write' }).click();
		// Scope the assertion to the root group: once Company is Write, the
		// CompanyMembership child shows the same inherited level and a
		// card-wide '.grants-segment-on' would match two elements.
		await expect(levelGroup.locator('.grants-segment-on')).toHaveText('Write');

		await page.getByRole('button', { name: 'Continue' }).click();
		await expect(page).toHaveURL(/\/Configure\/apps\/new\/review\?app=/);
	});

	let wizardAppId = '';
	await phase('wizard: review publishes; credentials shows the client_id', async () => {
		// The review checklist restates what was chosen, in counts. The
		// grants editor materialises inherited children on every emission,
		// so the authored crm.Company write is stored as two entries: Company
		// and its inherited child CompanyMembership.
		await expect(page.getByText('1 origin(s)')).toBeVisible();
		await expect(page.getByText('1 URI(s)')).toBeVisible();
		await expect(page.getByText('2 grant(s)')).toBeVisible();

		await page.getByRole('button', { name: 'Publish' }).click();
		await expect(page).toHaveURL(/\/Configure\/apps\/new\/credentials\?app=/);
		await expect(page.getByRole('heading', { name: `${APP_DISPLAY_NAME} is live` })).toBeVisible();

		// The create hook autogenerated the client_id — the credentials
		// screen is the product surface that reveals it.
		const clientIdCode = page
			.locator('.credentials-card .cred-row')
			.filter({ hasText: 'Client ID' })
			.locator('code');
		clientId = (await clientIdCode.innerText()).trim();
		expect(clientId).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);

		wizardAppId = new URL(page.url()).searchParams.get('app') ?? '';
		expect(wizardAppId).toBeTruthy();
	});

	await phase('registration: the projection reads back active', async () => {
		appId = wizardAppId;
		expect(await appField(request, appId, 'status')).toBe('active');
		expect(await appField(request, appId, 'client_id')).toBe(clientId);
		expect(await appField(request, appId, 'slug')).toBe(APP_SLUG);
	});

	// ── 2. Give the app its serving host ────────────────────────────────
	await phase('host: the app claims app.apps.localhost', async () => {
		// The wizard's host input does not exist yet (frontend follow-up) —
		// the host claim is one API patch, read back through the projection.
		await patchAppField(request, appId, 'host', APP_HOST);
		expect(await appField(request, appId, 'host')).toBe(APP_HOST);
	});

	// ── 3. Arrange the fresh CRM row the app token will read ───────────
	await phase('arrange: one fresh crm.Company exists for the token read', async () => {
		const response = await request.post(COMPANY_LIST_PATH, {
			headers: CSRF_HEADERS,
			data: { name: COMPANY_NAME }
		});
		expect(response.ok(), `creating ${COMPANY_NAME} must succeed (HTTP ${response.status()})`).toBe(
			true
		);
	});

	// ── 4. Deploy with the facet CLI ────────────────────────────────────
	await phase('cli: facet-cli deploy activates revision 1', async () => {
		// Build the mini-app input: fixture + the baked client id and API
		// origin. The bundle is one self-contained index.html.
		writeMiniappBuild(cliBuildDir, clientId, 1);

		writeFileSync(
			path.join(cliWorkspace, 'facet.config.json'),
			JSON.stringify(
				{
					app: APP_SLUG,
					outDir: cliBuildDir,
					spa: true,
					targets: { stack: { url: FACET_ORIGIN } },
					defaultTarget: 'stack'
				},
				null,
				'\t'
			)
		);

		const { stdout } = runCli(['deploy', '--note', 'e2e head-to-toe build'], {
			cwd: cliWorkspace,
			env: { FACET_TOKEN: facetToken }
		});
		// The CLI prints the assigned revision and, because activate is the
		// default, the app host it read off the registration.
		expect(stdout).toContain(`Deployed revision 1 (`);
		expect(stdout).toContain(`Active at https://${APP_HOST}`);

		const releases = runCli(['releases'], { cwd: cliWorkspace, env: { FACET_TOKEN: facetToken } });
		// `releases` marks the active deployment with `*`.
		expect(releases.stdout).toMatch(/^\* 1  /m);
	});

	await phase('cli: whoami reports the session and the active revision', async () => {
		const { stdout } = runCli(['whoami'], { cwd: cliWorkspace, env: { FACET_TOKEN: facetToken } });
		expect(stdout).toContain(`instance: ${FACET_ORIGIN}`);
		expect(stdout).toContain('admin@example.tld');
		expect(stdout).toContain('iam.Roles.admin');
		expect(stdout).toMatch(/app:\s+crudworks — revision 1 active \([0-9A-HJKMNP-TV-Z]{26}\)/);
	});

	// ── 5. Serving ──────────────────────────────────────────────────────
	// A separate page keeps the served-origin journey out of the admin
	// surface's console noise; page-error collection must stay honest.
	let pageErrors: string[] = [];
	const appPage: Page = await context.newPage();
	pageErrors = collectPageErrors(appPage);

	try {
		await phase('serve: the mini-app renders from its own host', async () => {
			const response = await appPage.goto(APP_URL);
			expect(response?.status(), 'the artifact stream must answer 200').toBe(200);
			expect(response?.headers()['content-type']).toContain('text/html');

			// The landing proves three surfaces at once: the static bundle
			// streams (HostCache → App::Hosting), the cross-origin discovery
			// read passes CORS, and the browser reached Facet over TLS.
			await expect(appPage.getByRole('heading', { name: 'CrudWorks Portal' })).toBeVisible();
			await expect(appPage.getByTestId('issuer')).toHaveText(FACET_ORIGIN);
		});

		await phase('serve: an unknown host answers a bare 404', async () => {
			const probe = await appPage.goto(UNKNOWN_HOST_URL);
			expect(probe?.status()).toBe(404);
			const body = (await probe?.text()) ?? '';
			expect(body).toContain('Not found');
		});

		await phase('serve: facet.localhost still falls through to the product', async () => {
			await appPage.goto('/');
			await expect(appPage.getByRole('heading', { name: /Hello Administrator/ })).toBeVisible();
		});

		// ── 6. OAuth from the served origin ─────────────────────────────
		await phase('oauth: consent names the app and returns the code', async () => {
			await appPage.goto(APP_URL);
			// Cross-origin top-level navigation into the authorization
			// surface — the admin session cookie re-attaches on facet host.
			await appPage.getByRole('button', { name: 'Sign in with Facet' }).click();
			await expect(appPage).toHaveURL(/\/\/facet\.localhost:3443\/OAuthConsent\?/);

			// The consent screen names the app, the disclosed redirect, and
			// the single usable role (admin ∩ crm.Company grant).
			await expect(
				appPage.getByRole('heading', { name: APP_DISPLAY_NAME, exact: false })
			).toBeVisible();
			await expect(appPage.getByText('This application will be able to')).toBeVisible();
			await expect(appPage.getByText(APP_REDIRECT_URI)).toBeVisible();
			await expect(appPage.getByText('Acting as')).toContainText('Admin');

			await appPage.getByRole('button', { name: 'Authorize' }).click();
			// The code lands back on the app's own origin, where the page
			// exchanges it under a DPoP proof.
			await expect(appPage).toHaveURL(
				new RegExp(`^${escapeRegExp(APP_ORIGIN)}/oauth/callback\\?code=`)
			);
		});

		await phase('oauth: the callback issues a DPoP-bound app token', async () => {
			// The token exchange runs inside the served page; the session
			// panel renders what the SPA received and decoded.
			await expect(appPage.getByTestId('token-type')).toHaveText('DPoP', { timeout: 15_000 });
			// The access token's role claim carries the qualified role id; the
			// consent screen already proved the human-readable "Admin" label.
			await expect(appPage.getByTestId('role')).toHaveText('iam.Roles.admin', { timeout: 15_000 });
			await expect(appPage.getByTestId('app-claim')).not.toHaveText('(none)');
			// cnf.jkt echoes the proof key's thumbprint back and the page
			// compares it against the key it generated.
			await expect(appPage.getByTestId('jkt')).toContainText('matches the proof key');
		});

		await phase('oauth: the app token reads CRM companies', async () => {
			// The DPoP-bound API call rides CORS from the served origin.
			await expect(appPage.getByTestId('companies-note')).toContainText(
				'company row(s) read with the DPoP-bound token'
			);
			await expect(appPage.getByTestId('companies')).toContainText(COMPANY_NAME);
			await expect(appPage.getByTestId('companies')).toContainText('Acme Corp');
		});

		await phase('oauth: the served-origin happy path ran without page errors', async () => {
			expect(pageErrors, `page errors: ${pageErrors.join(' | ')}`).toEqual([]);
		});

		// ── 7. DPoP enforcement, probed from the runner ─────────────────
		const bound = await readBoundSession(appPage);
		await phase('dpop: discovery answers publicly over TLS', async () => {
			const discovery = await request.get('/.well-known/oauth-authorization-server');
			expect(discovery.status()).toBe(200);
			const doc = await discovery.json();
			expect(doc.issuer).toBe(FACET_ORIGIN);
			expect(doc.authorization_endpoint).toBe(`${FACET_ORIGIN}/OAuth/authorize`);
			expect(doc.token_endpoint).toBe(`${FACET_ORIGIN}/OAuth/token`);
			expect(doc.code_challenge_methods_supported).toContain('S256');
		});

		await test.step('dpop: a bound token must ride the DPoP scheme with a fresh proof', async () => {
			// A cookie-FREE request context: the project's storageState would
			// otherwise ride along and authenticate every probe through the
			// admin session — masking exactly the token auth these probes
			// exercise (the miniapp's own in-page read is cross-origin, so the
			// SameSite cookie never travels with it). storageState must be
			// emptied EXPLICITLY: the shared config value leaks into
			// playwright.request.newContext() too.
			const bare = await playwright.request.newContext({
				baseURL: FACET_ORIGIN,
				ignoreHTTPSErrors: true,
				storageState: { cookies: [], origins: [] }
			});
			try {
				await runDpopProbes(bare, bound);
			} finally {
				await bare.dispose();
			}
		});

		// ── 7b. The app assistant (@facetapp/chat) ───────────────────
		// The window mounted during the OAuth callback load (the fixture
		// opens it whenever a session exists). The conversation create is the
		// one route the assistant gate guards, so the phases drive it: denied
		// while the app flag is off, enabled through the settings tab, then
		// created through the package against the live stack. No turn is ever
		// streamed: the stack's assistant provider is a dead stub (D11), and
		// conversation storage never calls it.
		const win = appPage.locator('facet-assistant-window');

		await phase('assistant: the package window displays in the served app', async () => {
			// The fixture's mount note proves the bundle loaded and the facade
			// opened with the token's app id.
			await expect(appPage.getByTestId('assistant-note')).toContainText(
				`${ASSISTANT_NAME} mounted for app ${appId}`
			);
			// The window chrome renders expanded: the collapse toggle carries
			// `aria-pressed = !collapsed`, so `true` here means the chat body
			// is on screen (not collapsed).
			await expect(win.getByRole('button', { name: 'Collapse assistant' })).toHaveAttribute(
				'aria-pressed',
				'true'
			);
			await expect(win.getByRole('dialog', { name: 'Assistant' })).toBeAttached();
			await expect(win.getByText(ASSISTANT_NAME)).toBeVisible();
			await expect(win.getByText('Conversations', { exact: true })).toBeVisible();
			// The empty rail is the list round trip: cross-origin GET with the
			// DPoP proof, owner-scoped, filtered to this app's conversations.
			await expect(win.getByText('No conversations yet.')).toBeVisible();
		});

		await phase('assistant: the disabled app denies the conversation create', async () => {
			await win.getByRole('button', { name: '+ New' }).click();
			await expect(win.getByText('Assistant unavailable')).toBeVisible();
			await expect(
				win.getByText(
					'The assistant is not enabled for this app, or your role does not include assistant access.'
				)
			).toBeVisible();
		});

		await phase('assistant: the settings tab enables the app assistant', async () => {
			await appPage.goto(`${FACET_ORIGIN}/Configure/apps/${APP_SLUG}/settings`);
			const section = appPage.locator('section.block').filter({
				has: appPage.getByRole('switch', { name: 'Enable the assistant' })
			});
			await section.getByRole('switch', { name: 'Enable the assistant' }).click();
			await section.getByRole('button', { name: 'Save' }).click();
			await expect(section.getByRole('switch', { name: 'Enable the assistant' })).toHaveAttribute(
				'aria-checked',
				'true'
			);
			// The gate reads the app projection live — read it back through
			// the same API the toggle's PATCH drives.
			expect(await appField(request, appId, 'assistant_enabled')).toBe(true);
		});

		await phase('assistant: the enabled app opens a conversation end to end', async () => {
			// Back to the app origin: the fixture restores the session from
			// sessionStorage and remounts the assistant.
			await appPage.goto(APP_URL);
			await expect(appPage.getByTestId('token-type')).toHaveText('DPoP');
			await expect(appPage.getByTestId('assistant-note')).toContainText(
				`${ASSISTANT_NAME} mounted for app ${appId}`
			);

			await win.getByRole('button', { name: '+ New' }).click();
			await expect(win.getByText('Send a message to start this conversation.')).toBeVisible();
			await expect(win.getByRole('textbox', { name: 'Type a message…' })).toBeVisible();
			// The rail row re-lists through the app filters: the conversation
			// the package created is an app-kind conversation of this app.
			await expect(win.getByText('app conversation')).toBeVisible();

			// Server-side read-back with the admin token: the reserved kind
			// carries the app id and the owner the backend derived (never a
			// request value), and the list scoping surfaces it to the owner.
			const list = await request.get(
				`/Api/assistant/conversations?filters[context.kind__eq]=app&filters[context.app_id__eq]=${appId}`
			);
			expect(list.status(), 'the app conversation list must answer 200').toBe(200);
			const { data } = await list.json();
			const row = (data as Array<{ context?: Record<string, unknown> }>).find(
				(c) => c.context?.['app_id'] === appId
			);
			expect(
				row,
				'the conversation the package created must appear in the app-scoped list'
			).toBeTruthy();
			expect(row?.context?.['kind']).toBe('app');
			expect(row?.context?.['created_by']).toBeTruthy();
		});
	} finally {
		await appPage.close();
	}

	// ── 8. Rollback through the CLI ─────────────────────────────────
	// Activating an older revision is a plain PATCH on app.App
	// (`active_deployment`), so the credential that deploys must also be
	// allowed to update the app document: the seeded facet-cli grant carries
	// write (create + update) on app.App, and a reference write consults no
	// grant on app.Deployment — ReferenceCheck verifies existence only.
	const bareServe = await playwright.request.newContext({
		baseURL: APP_ORIGIN,
		ignoreHTTPSErrors: true,
		storageState: { cookies: [], origins: [] }
	});
	try {
		await phase('cli: facet-cli deploy activates revision 2', async () => {
			// A real rebuild: same folder, new bytes, one deploy command.
			writeMiniappBuild(cliBuildDir, clientId, 2);
			const { stdout } = runCli(['deploy', '--note', 'e2e revision 2'], {
				cwd: cliWorkspace,
				env: { FACET_TOKEN: facetToken }
			});
			expect(stdout).toContain('Deployed revision 2 (');
			expect(stdout).toContain(`Active at https://${APP_HOST}`);
		});

		await phase('rollback: the served build flips to revision 2', async () => {
			await expectServedRevision(bareServe, 2);
		});

		await phase('cli: facet-cli rollback returns to revision 1', async () => {
			const { stdout } = runCli(['rollback', '1'], {
				cwd: cliWorkspace,
				env: { FACET_TOKEN: facetToken }
			});
			expect(stdout).toMatch(
				/Revision 1 \([0-9A-HJKMNP-TV-Z]{26}\) is now the active deployment\./
			);
		});

		await phase('rollback: the served build flips back to revision 1', async () => {
			await expectServedRevision(bareServe, 1);
		});

		await phase('cli: releases and whoami read the rolled-back state', async () => {
			const releases = runCli(['releases'], {
				cwd: cliWorkspace,
				env: { FACET_TOKEN: facetToken }
			});
			// Revision 1 is active again; revision 2 stays listed, unmarked.
			expect(releases.stdout).toMatch(/^\* 1  /m);
			expect(releases.stdout).toContain('e2e revision 2');
			expect(releases.stdout).toMatch(/^  2  /m);
			expect(releases.stdout).not.toMatch(/^\* 2/m);

			const whoami = runCli(['whoami'], {
				cwd: cliWorkspace,
				env: { FACET_TOKEN: facetToken }
			});
			expect(whoami.stdout).toMatch(
				/app:\s+crudworks — revision 1 active \([0-9A-HJKMNP-TV-Z]{26}\)/
			);
		});
	} finally {
		await bareServe.dispose();
	}
});

/**
 * Records uncaught page errors so the happy path may assert it ran clean.
 */
function collectPageErrors(page: Page): string[] {
	const errors: string[] = [];
	page.on('pageerror', (error) => errors.push(error.message));
	return errors;
}

/**
 * The DPoP enforcement probes, run against a cookie-free request context:
 * positive control, jti replay, Bearer downgrade, and the missing-proof
 * fail-closed case.
 */
async function runDpopProbes(client: APIRequestContext, bound: BoundSession): Promise<void> {
	expect(bound.access_token, 'the callback must persist its issued token').toBeTruthy();
	expect(bound.jkt, 'the callback must persist its DPoP public key').toBeTruthy();

	// The htu the server reconstructs: public origin + path only.
	const htu = `${FACET_ORIGIN}${COMPANY_LIST_PATH}`;
	const ath = await sha256B64url(bound.access_token);

	// Positive control: a fresh proof signed with the bound key.
	const first = await signedProof(bound, 'GET', htu, ath);
	const ok = await client.get(COMPANY_LIST_PATH, {
		headers: { Authorization: `DPoP ${bound.access_token}`, DPoP: first }
	});
	expect(ok.status(), 'a correct DPoP presentation must read the API').toBe(200);

	// Replay: the same proof bytes again — the jti is burned.
	const replay = await client.get(COMPANY_LIST_PATH, {
		headers: { Authorization: `DPoP ${bound.access_token}`, DPoP: first }
	});
	expect(replay.status(), 'a replayed proof must fail').toBe(401);

	// Downgrade guard: a cnf-bearing token under `Bearer` fails even with a
	// valid fresh proof attached.
	const bearerProof = await signedProof(bound, 'GET', htu, ath);
	const bearer = await client.get(COMPANY_LIST_PATH, {
		headers: { Authorization: `Bearer ${bound.access_token}`, DPoP: bearerProof }
	});
	expect(bearer.status(), 'Bearer-presented bound tokens must fail closed').toBe(401);

	// Missing proof: the token is bound to its key.
	const proofless = await client.get(COMPANY_LIST_PATH, {
		headers: { Authorization: `DPoP ${bound.access_token}` }
	});
	expect(proofless.status(), 'a bound token without a proof must fail').toBe(401);
}
