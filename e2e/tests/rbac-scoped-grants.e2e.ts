// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	test,
	expect,
	type APIRequestContext,
	type Browser,
	type BrowserContext,
	type Page
} from '@playwright/test';

/**
 * RBAC scoped grants: the three scope
 * mechanisms on their real surfaces — a named scope on a doctype definition
 * (`$mine`, `$global`), a context set routed through a named scope
 * (`$mine_set` → the domain's `my_companies` set), and the sidecar
 * nested-grant rule.
 *
 * Actors and roles:
 * - `alice` / `bob` hold the arranged `scoped_reader` role: `read
 *   crm.Company` with a scope, plus `read core.DocType` — every
 *   `/{domain}/{Doctype}` route load fetches the `core.DocType` registry,
 *   so a UI-capable role needs that line. It exposes schema metadata,
 *   never row data.
 * - `carol` holds the seeded `comment_author` role, extended in the sidecar
 *   step with `read core.DocType`, `read crm.Company ["$mine"]`, and both
 *   nested-grant spellings (see that step for why both).
 *
 * The active role resolves role content fresh on every request, so the
 * mid-file role patches apply to already-open browser sessions without a
 * re-login.
 *
 * WebSocket step: a scripted client in a second context
 * (carol's cookies) subscribes BOTH the collection path and the document
 * path of Initech. The collection channel is the only surface with a
 * per-emit RBAC filter; the document channel gates at subscribe time only.
 * Frames are asserted on channel + payload id + headers — never on content
 * (the payload carries the id only, `doc/backend/websocket.md`).
 */

// ── Constants ──────────────────────────────────────────────────────────────

/** Seeded `crm.Company` rows (the CRM bundle imports ids `crm.Company.1–3`). */
const ACME_ID = 'crm.Company.1';
const GLOBEX_ID = 'crm.Company.2';
const INITECH_ID = 'crm.Company.3';
const ACME_NAME = 'Acme Corp';
const GLOBEX_NAME = 'Globex Inc';
const INITECH_NAME = 'Initech';

const ALICE_EMAIL = 'alice@example.tld';
const ALICE_NAME = 'Alice Meyer';
const BOB_EMAIL = 'bob@example.tld';
const BOB_NAME = 'Bob Ferreira';
const CAROL_EMAIL = 'carol@example.tld';
const CAROL_NAME = 'Carol Ionescu';

/** The permanent password set through every forced-change screen. */
const PERMANENT_PASSWORD = 'Scoped-Grant-E2E-97';

const SCOPED_READER = 'scoped_reader';
/**
 * The scenario creates the scoped_reader role through `POST /Api/iam/Roles`.
 * The role `name` is immutable after creation (the update hook refuses any
 * PATCH that carries it) because the document id is `iam.Roles.<name>` — the
 * dotted form the account's `roles` reference array stores and login resolves
 * with an exact id match. A role must therefore be created under its final
 * name; renaming is the documented dead end ("recreate the role under the
 * new name"), and the old in-place rename of the seeded viewer role is no
 * longer valid.
 */
const SCOPED_READER_REF = `iam.Roles.${SCOPED_READER}`;
const COMMENT_AUTHOR_ROLE = 'iam.Roles.comment_author';

/** The comment texts the two nested-grant spellings produce. */
const DIRECT_GRANT_COMMENT = 'Direct nested grant: the create hook forces the author.';
const UI_GRANT_COMMENT = 'Comment posted through the composer.';

/**
 * The CSRF surface for scripted JSON writes (same contract as the other
 * scenarios): the `X-Requested-With` header (`HTTP::Helpers.require_csrf`).
 */
const CSRF_HEADERS = { 'X-Requested-With': 'XMLHttpRequest' as const };

/** Time the WS negative assertion waits after the out-of-scope mutation. */
const WS_SETTLE = 4_000;

// ── Helpers ────────────────────────────────────────────────────────────────

/** Logs each phase before running it: the list reporter stays silent until a
 * test finishes, so a long phase must say its name or a slow run is
 * indistinguishable from a hang. */
async function phase(name: string, body: () => Promise<void>): Promise<void> {
	console.log(`\n[${new Date().toISOString().slice(11, 19)}] >> ${name}`);
	await test.step(name, body);
}

/** GETs JSON and asserts the round trip succeeded. */
async function getJson(
	request: APIRequestContext,
	path: string,
	message: string
): Promise<{ data: Record<string, unknown>; meta?: Record<string, unknown> }> {
	const response = await request.get(path);
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 400)}`
	).toBe(true);
	return JSON.parse(body);
}

/** POSTs JSON and asserts the write landed (CSRF-checked route). */
async function postJson(
	request: APIRequestContext,
	path: string,
	data: Record<string, unknown>,
	message: string
): Promise<{ data: Record<string, unknown>; meta: Record<string, unknown> }> {
	const response = await request.post(path, { headers: CSRF_HEADERS, data });
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 400)}`
	).toBe(true);
	return JSON.parse(body);
}

/** PATCHes JSON and asserts the write landed (CSRF-checked route). */
async function patchJson(
	request: APIRequestContext,
	path: string,
	data: Record<string, unknown>,
	message: string
): Promise<{ data: Record<string, unknown>; meta: Record<string, unknown> }> {
	const response = await request.patch(path, { headers: CSRF_HEADERS, data });
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 400)}`
	).toBe(true);
	return JSON.parse(body);
}

/** PUTs the full doctype definition (the `Doctype::Update` authoring surface). */
async function putDoctypeDefinition(
	request: APIRequestContext,
	qualifiedId: string,
	definition: Record<string, unknown>,
	message: string
): Promise<void> {
	const response = await request.put(`/Api/core/DocType/${encodeURIComponent(qualifiedId)}`, {
		headers: CSRF_HEADERS,
		data: definition
	});
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 600)}`
	).toBe(true);
}

/**
 * Creates an `iam.Account` document and assigns it one role. The create hook
 * starts every human account `pending`; the temporary password (returned
 * once) starts the bootstrap. `roleRef` is the qualified role-document
 * reference — the same form the account's `roles` array stores and login
 * resolves (`iam.Roles.<id>`; a created role's raw projection id is a ULID).
 * Returns `{ id, tempPassword }`.
 */
async function createAccountWithRole(
	request: APIRequestContext,
	email: string,
	displayName: string,
	roleRef: string
): Promise<{ id: string; tempPassword: string }> {
	const created = await postJson(
		request,
		'/Api/iam/Account',
		// The account doctype's human-label field is `name` (titled "Display
		// Name" in the UI); the old `display_name` key no longer exists.
		{ email, name: displayName },
		`creating the ${email} account`
	);
	const id = String(created.meta.id);
	expect(id, 'the account create returns a document id').toBeTruthy();

	await patchJson(
		request,
		`/Api/iam/Account/${id}`,
		{ roles: [roleRef], default_role: roleRef },
		`assigning the role to ${email}`
	);

	// The operator route writes a bare payload — no {data, meta} envelope —
	// and reveals the plaintext exactly once.
	const tempResponse = await request.post(`/Api/iam/accounts/${id}/temporary-password`, {
		headers: CSRF_HEADERS,
		data: {}
	});
	const tempBody = (await tempResponse.text()) as string;
	expect(
		tempResponse.ok(),
		`minting the temporary password for ${email} must succeed (HTTP ${tempResponse.status()}): ${tempBody.slice(0, 300)}`
	).toBe(true);
	const tempPassword = (JSON.parse(tempBody) as { temporary_password?: unknown }).temporary_password;
	expect(
		typeof tempPassword === 'string' && tempPassword.length > 8,
		'the temporary password is revealed once in the response'
	).toBe(true);
	return { id, tempPassword: String(tempPassword) };
}

/**
 * A truly anonymous context. `browser.newContext()` inside a test inherits
 * the project `use` context options — including the admin `storageState` —
 * so every manual context must override it with an empty jar, or `/Login`
 * bounces straight back to the dashboard.
 */
function anonymousContext(browser: Browser): Promise<BrowserContext> {
	return browser.newContext({ storageState: { cookies: [], origins: [] } });
}

/**
 * Mints a browser session through the real login flow (the same path the
 * setup project pins): temporary password → the `must_change_password` hold
 * → forced change → active session. Returns when the context holds the
 * session cookies; the dashboard landing itself is NOT asserted — a
 * restricted role may render a reduced shell, and the cookies are what the
 * later steps consume.
 */
async function loginThroughUi(page: Page, email: string, tempPassword: string): Promise<void> {
	await page.goto('/Login');
	// The login form hydrates after SSR. A click that lands before hydration
	// submits the form natively, with the credentials in the URL. Wait for the
	// bundle to settle before the form is touched.
	await page.waitForLoadState('networkidle', { timeout: 15_000 });
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(tempPassword);
	await page.getByRole('button', { name: 'Sign in' }).click();

	// The `must_change_pw` branch renders ForcedChangeScreen, not the app.
	await expect(page.getByRole('heading', { name: 'Set a new password' })).toBeVisible();

	await page.getByLabel('Current password').fill(tempPassword);
	// Exact label matching resolves to nothing here: the Field renders the
	// required marker inside the label element, and "New password" alone
	// also substring-matches the confirm field. Target the label-wired id
	// (proven in user-lifecycle).
	await page.locator('input[id="input-New password"]').fill(PERMANENT_PASSWORD);
	await page.getByLabel('Confirm new password').fill(PERMANENT_PASSWORD);
	await page.getByRole('button', { name: 'Save password and continue' }).click();

	await expect(page).not.toHaveURL(/\/Login/);
}

/** Escapes a literal for use inside `new RegExp`. */
function escapeRegExp(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** The list table's row for one company name. */
function companyRow(page: Page, name: string) {
	return page.getByRole('row', { name: new RegExp(escapeRegExp(name)) });
}

/** A frame the `/Ws` bridge delivers (an error frame sets `error`). */
interface WsFrame {
	channel?: string;
	event?: string;
	payload?: { id?: string };
	headers?: Record<string, unknown>;
	error?: string;
	path?: string;
}

type WsWindow = Window & { __wsFrames?: WsFrame[]; __wsState?: string };

// ── The scenario ───────────────────────────────────────────────────────────

test('rbac scoped grants: named scopes, context sets, sidecar nested grants', async ({
	page,
	browser,
	request
}) => {
	test.setTimeout(9 * 60_000);

	let aliceId = '';
	let bobId = '';
	let carolId = '';
	let aliceTempPassword = '';
	let bobTempPassword = '';
	let carolTempPassword = '';
	let aliceContext: BrowserContext | null = null;
	let bobContext: BrowserContext | null = null;
	let carolContext: BrowserContext | null = null;
	let wsContext: BrowserContext | null = null;
	let adminAccountId = '';

	// ── 1. Named scopes on the doctype (step 1, arrange) ────────────────
	await phase('arrange: crm.Company declares the mine and global named scopes', async () => {
		const def = await getJson(request, '/Api/core/DocType/crm.Company', 'the Company definition');

		await putDoctypeDefinition(
			request,
			'crm.Company',
			{
				...def.data,
				scopes: {
					mine: {
						description: 'Companies owned by the actioner',
						where: { owner_id: '$self' }
					},
					global: {
						description: 'Companies nobody owns',
						where: { owner_id: '$null' }
					}
				}
			},
			'adding the named scopes to crm.Company'
		);

		const reread = await getJson(
			request,
			'/Api/core/DocType/crm.Company',
			'the Company definition after the scope write'
		);
		const scopes = reread.data.scopes as Record<string, { where: Record<string, string> }>;
		expect(scopes.mine.where).toEqual({ owner_id: '$self' });
		expect(scopes.global.where).toEqual({ owner_id: '$null' });
	});

	await phase('arrange: the scoped_reader role is created under its final name', async () => {
		// The scenario owns its stack, and the plan arranges the role by API —
		// "create a role". The role document id is `iam.Roles.<name>` and the
		// name is immutable (see SCOPED_READER_REF), so the create already
		// carries the final name; the account create in the next phase assigns
		// the role by that dotted id.
		const created = await postJson(
			request,
			'/Api/iam/Roles',
			{
				name: SCOPED_READER,
				// `level` is required (role authority): a caller may only author
				// or assign roles at or below its elected role's level. The
				// seeded admin holds level 100; a read-only helper role sits
				// below the seeded viewer (20).
				level: 10,
				description:
					'E2E: read crm.Company rows owned by the actioner, plus the DocType registry the UI routes fetch.',
				permissions: [
					{ action: 'read', on: 'crm.Company', scope: ['$mine'] },
					{ action: 'read', on: 'core.DocType' }
				]
			},
			'creating the scoped_reader role'
		);
		expect(created.meta.id).toBe(SCOPED_READER_REF);
		expect(created.data.name).toBe(SCOPED_READER);
	});

	// ── 2. Accounts and ownership (step 2, arrange) ─────────────────────
	await phase('arrange: alice and bob hold scoped_reader; alice owns Acme', async () => {
		const alice = await createAccountWithRole(
			request,
			ALICE_EMAIL,
			ALICE_NAME,
			SCOPED_READER_REF
		);
		aliceId = alice.id;
		aliceTempPassword = alice.tempPassword;
		const bob = await createAccountWithRole(
			request,
			BOB_EMAIL,
			BOB_NAME,
			SCOPED_READER_REF
		);
		bobId = bob.id;
		bobTempPassword = bob.tempPassword;

		// Reference fields store the qualified form; `$self` expands to the
		// same form (`RBAC.qualify_principal`), so the scope predicate and
		// the stored value agree.
		await patchJson(
			request,
			`/Api/crm/Company/${ACME_ID}`,
			{ owner_id: `iam.Account.${aliceId}` },
			'giving alice ownership of Acme'
		);
		const acme = await getJson(
			request,
			`/Api/crm/Company/${ACME_ID}`,
			'the Acme row after the owner patch'
		);
		expect(acme.data.owner_id).toBe(`iam.Account.${aliceId}`);
	});

	// ── 3. Alice's list shows exactly her row (step 3) ──────────────────
	await phase('alice: the list surface shows exactly the owned company', async () => {
		aliceContext = await anonymousContext(browser);
		const alicePage = await aliceContext.newPage();
		await loginThroughUi(alicePage, ALICE_EMAIL, aliceTempPassword);

		await alicePage.goto('/crm/Company');
		await expect(companyRow(alicePage, ACME_NAME)).toBeVisible();
		await expect(companyRow(alicePage, GLOBEX_NAME)).toHaveCount(0);
		// Initech has no asserted display-name collision; assert by id.
		await expect(alicePage.getByRole('row', { name: new RegExp(INITECH_ID) })).toHaveCount(0);
	});

	// ── 4. Alice's direct read of a foreign row is denied (plan step 4) ─
	await phase('alice: the not-owned company read is denied without a leak', async () => {
		const alicePage = (aliceContext as BrowserContext).pages()[0];
		await alicePage.goto(`/crm/Company/${GLOBEX_ID}`);

		// The single-read path denies non-disclosing — the SSR fetch fails
		// and the route load throws the 404 error page.
		await expect(
			alicePage.getByRole('heading', { name: 'The page could not be found' })
		).toBeVisible();
		await expect(alicePage.getByText(GLOBEX_NAME)).toHaveCount(0);
	});

	// ── 5. Bob owns nothing: zero rows, no error noise (plan step 5) ────
	await phase('bob: the scoped list is empty and quiet', async () => {
		bobContext = await anonymousContext(browser);
		const bobPage = await bobContext.newPage();
		await loginThroughUi(bobPage, BOB_EMAIL, bobTempPassword);

		await bobPage.goto('/crm/Company');
		await expect(bobPage.getByRole('row', { name: 'No records' })).toBeVisible();
		await expect(companyRow(bobPage, ACME_NAME)).toHaveCount(0);
		// "No error noise": the table's error banner never renders.
		await expect(bobPage.locator('.table-error')).toHaveCount(0);
	});

	// ── 6. OR of scopes (step 6) ────────────────────────────────────────
	await phase('or-semantics: $mine OR $global shows the ownerless company', async () => {
		await patchJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(SCOPED_READER_REF)}`,
			{
				permissions: [
					{ action: 'read', on: 'crm.Company', scope: ['$mine', '$global'] },
					{ action: 'read', on: 'core.DocType' }
				]
			},
			'widening scoped_reader to the OR of mine and global'
		);

		await patchJson(
			request,
			`/Api/crm/Company/${GLOBEX_ID}`,
			{ owner_id: null },
			'clearing the Globex owner'
		);

		const alicePage = (aliceContext as BrowserContext).pages()[0];
		await alicePage.goto('/crm/Company');
		await expect(companyRow(alicePage, ACME_NAME)).toBeVisible();
		await expect(companyRow(alicePage, GLOBEX_NAME)).toBeVisible();
	});

	// ── 7. Context set (step 7) ─────────────────────────────────────────
	await phase('context set: $mine_set routes the scope through my_companies', async () => {
		// Order matters: the named-scope validator resolves `$<context_set>`
		// against the domain, and the role validator resolves `$<alias>`
		// against the doctype — domain first, doctype second, role last.
		await patchJson(
			request,
			'/Api/core/Domain/crm',
			{
				context_sets: {
					my_companies: {
						from: 'Company',
						where: { owner_id: '$self' },
						// `select` projects a content field, not the row id —
						// the owner ids are the set values, and the named
						// scope compares `owner_id` against them.
						select: 'owner_id'
					}
				}
			},
			'declaring the my_companies context set on crm'
		);

		const def = await getJson(request, '/Api/core/DocType/crm.Company', 'the Company definition');
		const scopes = def.data.scopes as Record<string, unknown>;
		await putDoctypeDefinition(
			request,
			'crm.Company',
			{
				...def.data,
				scopes: {
					...scopes,
					mine_set: {
						description: 'Companies whose owner is in the caller’s my_companies set',
						where: { owner_id: '$my_companies' }
					}
				}
			},
			'adding the mine_set named scope to crm.Company'
		);

		await patchJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(SCOPED_READER_REF)}`,
			{
				permissions: [
					{ action: 'read', on: 'crm.Company', scope: ['$mine_set'] },
					{ action: 'read', on: 'core.DocType' }
				]
			},
			'narrowing scoped_reader to the context-set scope'
		);

		// Alice still sees exactly her owned row — now through the resolved
		// set; the ownerless row from step 6 drops out with the $global alias.
		const alicePage = (aliceContext as BrowserContext).pages()[0];
		await alicePage.goto('/crm/Company');
		await expect(companyRow(alicePage, ACME_NAME)).toBeVisible();
		await expect(companyRow(alicePage, GLOBEX_NAME)).toHaveCount(0);
	});

	await phase('context set: bob’s empty set fails closed', async () => {
		// Bob owns no company, so `my_companies` resolves empty for him; the
		// Eq-against-empty-set clause is `1=0` — not "match everything".
		const bobPage = (bobContext as BrowserContext).pages()[0];
		await bobPage.goto('/crm/Company');
		await expect(bobPage.getByRole('row', { name: 'No records' })).toBeVisible();
		await expect(companyRow(bobPage, ACME_NAME)).toHaveCount(0);
		await expect(bobPage.locator('.table-error')).toHaveCount(0);
	});

	// ── 8. Flat sidecar grant (step 8) ──────────────────────────────────
	await phase('flat sidecar: comment_author reads the flat endpoint; flat create is rejected', async () => {
		const carol = await createAccountWithRole(
			request,
			CAROL_EMAIL,
			CAROL_NAME,
			COMMENT_AUTHOR_ROLE
		);
		carolId = carol.id;
		carolTempPassword = carol.tempPassword;

		// Her browser session is minted once here and reused by the UI and
		// WS steps; the context-bound request shares the cookie jar.
		carolContext = await anonymousContext(browser);
		const carolPage = await carolContext.newPage();
		await loginThroughUi(carolPage, CAROL_EMAIL, carolTempPassword);

		const carolApi = (carolContext as BrowserContext).request;

		// Read works: 200 with an empty author-scoped set (she owns no
		// comment yet). A denial would surface as 403/404, never 200.
		const list = await getJson(carolApi, '/Api/core/Comment', 'the flat comment list');
		expect(list.meta?.count).toBe(0);

		// Flat create is blocked for sidecar doctypes before any RBAC runs.
		const flatCreate = await carolApi.post('/Api/core/Comment', {
			headers: CSRF_HEADERS,
			data: { body: 'Should never land through the flat route.' }
		});
		expect(flatCreate.status(), 'the flat sidecar create must be rejected').toBe(422);
		const flatBody = (await flatCreate.json()) as { error?: string };
		expect(flatBody.error).toContain('flat route');
	});

	// ── 9. Sidecar nested grant (step 9) ────────────────────────────────
	await phase('nested sidecar: the direct spelling authorises the API create; author forced', async () => {
		// The comment_author role gains the host read (both gates of the
		// nested route and the show page need it), the UI registry line, and
		// the nested grant in its DIRECT spelling. Carol also becomes the
		// owner of Initech so her $mine read reaches that one row.
		const role = await getJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(COMMENT_AUTHOR_ROLE)}`,
			'the comment_author role'
		);
		await patchJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(COMMENT_AUTHOR_ROLE)}`,
			{
				permissions: [
					...(role.data.permissions as Array<Record<string, unknown>>),
					{ action: 'read', on: 'core.DocType' },
					{ action: 'read', on: 'crm.Company', scope: ['$mine'] },
					{ action: 'create', on: 'crm.Company.Comment' }
				]
			},
			'extending comment_author with the host read and the direct nested grant'
		);

		await patchJson(
			request,
			`/Api/crm/Company/${INITECH_ID}`,
			{ owner_id: `iam.Account.${carolId}` },
			'giving carol ownership of Initech'
		);

		// The API probe pins the direct spelling end to end.
		const carolApi = (carolContext as BrowserContext).request;
		const created = await postJson(
			carolApi,
			`/Api/crm/Company/${INITECH_ID}/comments`,
			{ body: DIRECT_GRANT_COMMENT },
			'the nested comment create under the direct grant'
		);
		const commentId = String(created.meta.id);

		// The author is forced by the core.Comment create hook — a spoofed
		// author would have failed the hook, an omitted one is stamped.
		const comment = await getJson(request, `/Api/core/Comment/${commentId}`, 'the created comment');
		expect(comment.data.author).toBe(`iam.Account.${carolId}`);
	});

	await phase('nested sidecar: the host spelling drives the composer on the show page', async () => {
		// The composer's create hint checks the HOST path
		// (`can('crm.Company', 'create')`) against the /Api/iam/me manifest,
		// and the manifest is exact-key. The direct spelling alone would
		// keep the composer locked, so the role also carries `create
		// crm.Company` — the spelling that implies the nested grant by
		// prefix matching. Both spellings are now pinned.
		const role = await getJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(COMMENT_AUTHOR_ROLE)}`,
			'the comment_author role'
		);
		await patchJson(
			request,
			`/Api/iam/Roles/${encodeURIComponent(COMMENT_AUTHOR_ROLE)}`,
			{
				permissions: [
					...(role.data.permissions as Array<Record<string, unknown>>),
					{ action: 'create', on: 'crm.Company' }
				]
			},
			'adding the host create spelling to comment_author'
		);

		const carolPage = (carolContext as BrowserContext).pages()[0];
		await carolPage.goto(`/crm/Company/${INITECH_ID}`);
		await expect(
			carolPage.getByRole('heading', { name: INITECH_NAME })
		).toBeVisible();

		// The unlocked composer is itself the UI-level grant signal; the
		// locked variant would render "You cannot comment on this document."
		const composer = carolPage.getByTestId('comment-composer');
		await expect(composer).toBeVisible();
		await composer.locator('.ProseMirror').click();
		await carolPage.keyboard.type(UI_GRANT_COMMENT);
		await composer.getByRole('button', { name: 'Comment' }).click();

		// The panel reloads its thread after the POST; the comment renders
		// in the list (author label resolution is carol-scoped and may
		// degrade to a placeholder — the author identity is asserted via
		// the API above).
		await expect(carolPage.locator('.cs-thread')).toContainText(UI_GRANT_COMMENT);
	});

	// ── 10. WS delta (step 10) ──────────────────────────────────────────
	await phase('ws: the scoped subscriber receives in-scope frames only', async () => {
		// The admin identity for the actioner_id header assertion. The
		// profile route writes a bare payload — no {data, meta} envelope —
		// like the operator routes.
		const me = await getJson(request, '/Api/iam/me', 'the admin profile');
		const meAccount = (me as unknown as { account: Record<string, unknown> }).account;
		adminAccountId = String(meAccount.id);

		// Context B holds the same session under a fresh jar.
		wsContext = await browser.newContext({
			storageState: await (carolContext as BrowserContext).storageState()
		});
		const wsPage = await wsContext.newPage();
		await wsPage.goto('/');
		await expect(wsPage).not.toHaveURL(/\/Login/);

		await wsPage.evaluate((initechId) => {
			const w = window as WsWindow;
			w.__wsFrames = [];
			w.__wsState = 'connecting';
			const ws = new WebSocket(`wss://${window.location.host}/Ws`);
			ws.onopen = () => {
				w.__wsState = 'open';
				// The collection path carries the per-emit RBAC filter; the
				// document path is gated at subscribe time only.
				ws.send(
					JSON.stringify({
						action: 'subscribe',
						args: ['/crm/Company', `/crm/Company/${initechId}`]
					})
				);
			};
			ws.onerror = () => {
				w.__wsState = 'error';
			};
			ws.onclose = (e) => {
				w.__wsState = `closed:${e.code}`;
			};
			ws.onmessage = (m) => {
				w.__wsFrames?.push(JSON.parse(m.data) as WsFrame);
			};
		}, INITECH_ID);

		await expect
			.poll(() => wsPage.evaluate(() => (window as WsWindow).__wsState), {
				message: 'the socket upgrade must succeed'
			})
			.toBe('open');

		// No ack exists for a subscribe — a denial would arrive as an error
		// frame. A short beat proves both subscriptions were accepted (the
		// role ceiling holds read crm.Company for carol).
		await wsPage.waitForTimeout(800);
		const early = (await wsPage.evaluate(
			() => (window as WsWindow).__wsFrames ?? []
		)) as WsFrame[];
		expect(
			early.filter((f) => f.error !== undefined),
			'no subscribe-time error frame may arrive'
		).toEqual([]);

		// In-scope mutation: carol owns Initech, so the per-emit filter
		// delivers the collection frame, and the document frame rides its
		// own channel.
		const initechPatch = await patchJson(
			request,
			`/Api/crm/Company/${INITECH_ID}`,
			{ phone: '+1-555-0900' },
			'the admin updates the in-scope company'
		);
		const initechMutationId = String(
			(initechPatch.meta as Record<string, unknown>).mid ?? (initechPatch.meta as Record<string, unknown>).id ?? ''
		);
		let initechFrame: WsFrame | undefined;
		await expect
			.poll(async () => {
				const frames = (await wsPage.evaluate(
					() => (window as WsWindow).__wsFrames ?? []
				)) as WsFrame[];
				// `Event::Message.unpack` resolves the wire channel as
				// `{fanout channel}:{event}` — the delivered frame's channel
				// carries the event suffix, not the bare subscription channel.
				initechFrame = frames.find(
					(f) => f.channel === 'fanout:crm.Company:updated' && f.payload?.id === INITECH_ID
				);
				return initechFrame;
			})
			.not.toBeFalsy();

		expect(initechFrame?.event).toBe('updated');
		expect(initechFrame?.headers?.domain).toBe('crm');
		expect(initechFrame?.headers?.doc_type).toBe('Company');
		expect(initechFrame?.headers?.actioner_id).toBe(adminAccountId);
		expect(String(initechFrame?.headers?.mutation_id ?? '')).toBeTruthy();
		if (initechMutationId) {
			expect(initechFrame?.headers?.mutation_id).toBe(initechMutationId);
		}

		// The document channel delivered the same mutation too.
		const docFrames = (await wsPage.evaluate(
			() => (window as WsWindow).__wsFrames ?? []
		)) as WsFrame[];
		expect(
			docFrames.some((f) => f.channel === `fanout:crm.Company:${INITECH_ID}:updated`),
			'the document channel delivers the in-scope mutation'
		).toBe(true);

		// Out-of-scope mutation: Globex is owned by nobody carol's scope
		// matches. The PATCH response returns after the event flush, so a
		// settle window is enough to prove suppression.
		await patchJson(
			request,
			`/Api/crm/Company/${GLOBEX_ID}`,
			{ phone: '+1-555-0901' },
			'the admin updates the out-of-scope company'
		);
		await wsPage.waitForTimeout(WS_SETTLE);

		const finalFrames = (await wsPage.evaluate(
			() => (window as WsWindow).__wsFrames ?? []
		)) as WsFrame[];
		expect(
			finalFrames.filter((f) => f.payload?.id === GLOBEX_ID),
			'no frame for the out-of-scope mutation may arrive on any channel'
		).toEqual([]);
	});

	// ── Teardown of the manual contexts ─────────────────────────────────
	await phase('teardown: close the scenario contexts', async () => {
		await wsContext?.close();
		await carolContext?.close();
		await bobContext?.close();
		await aliceContext?.close();
	});
});
