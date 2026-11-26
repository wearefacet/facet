// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { test, expect, type APIRequestContext } from '@playwright/test';

/**
 * Field containment: a tagged-down Real caller never sees an invisible
 * field's value on any surface, and never writes through it.
 *
 * The scenario creates its own domain and doctype over the authoring API
 * (`POST /Api/core/Domain` then `POST /Api/core/DocType`), tags one field
 * `confidential`, then mints a non-admin account holding the seeded
 * `editor` role (`visible_tags: ["default"]` — the tag-down caller). The
 * five guards the file pins:
 *
 * 1. masked GET — `Document::Read` (`RBAC::ReadEnforcer.mask_content`);
 * 2. masked write response — `write_document_result` → `Document::Presenter`
 *    (`src/http/responders.cr`); the PATCH of a visible field must not echo
 *    the hidden value back;
 * 3. masked history — `Audit::List` → `Audit::Redact` (`src/audit/redact.cr`);
 *    the create row's `arguments.content` loses the value, the update diff
 *    keeps the path but loses it, and the removed paths land in the
 *    out-of-band `redacted` metadata;
 * 4. invisible-field write refusal — `Document::Update` →
 *    `RBAC::WriteEnforcer` (403 "Write refused: invisible field");
 * 5. role self-escalation refusal — `RBAC::RoleAuthority`
 *    (403 "Role authority refused this write"); the editor (level 30) must
 *    not add `iam.Roles.admin` (level 100) to its own account.
 *
 * The scenario drives the API only (harness §4: arrange with the API): the
 * non-admin actor authenticates through the real login flow and every
 * assertion runs on a context-bound `request` sharing that session jar.
 */

// ── Constants ──────────────────────────────────────────────────────────────

/** The domain and doctype the scenario owns (fresh per stack). */
const DOMAIN = 'vault';
const DOCTYPE = 'Ledger';

/** The hidden field's tag and the value that must never leak. */
const HIDDEN_TAG = 'confidential';
const HIDDEN_FIELD = 'secret_note';
const HIDDEN_VALUE = 'payroll-topup-9137';

/** The visible fields the caller may write and read. */
const VISIBLE_FIELD = 'name';
const VISIBLE_VALUE_INITIAL = 'Ledger row one';
const VISIBLE_VALUE_UPDATED = 'Ledger row one (revised)';

/** The seeded non-admin role the scenario assigns (stack baseline). */
const EDITOR_ROLE_REF = 'iam.Roles.editor';
const EDITOR_EMAIL = 'vault.editor@example.tld';
const EDITOR_NAME = 'Vera Vaultkeeper';
const EDITOR_PASSWORD = 'Containment-E2E-41';

/** The role reference the self-escalation attempt adds to the actor's own account. */
const ADMIN_ROLE_REF = 'iam.Roles.admin';

/** The CSRF surface for scripted JSON writes (`HTTP::Helpers.require_csrf`). */
const CSRF_HEADERS = { 'X-Requested-With': 'XMLHttpRequest' as const };

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

/** Creates one history-history page's rows shape: { data: [...], meta } */
interface HistoryRow {
	action: string;
	arguments: Record<string, unknown>;
	redacted: string[][];
}

/**
 * Creates an `iam.Account` and assigns it one role — the
 * `rbac-scoped-grants` pattern: create (starts `pending`), PATCH the role
 * refs, mint the one-time temporary password through the operator route.
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
		`assigning ${roleRef} to ${email}`
	);

	const tempResponse = await request.post(`/Api/iam/accounts/${id}/temporary-password`, {
		headers: CSRF_HEADERS,
		data: {}
	});
	const tempBody = await tempResponse.text();
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
 * Mints a browser session through the real login flow (temporary password →
 * forced change → active). Returns when the context holds the session
 * cookies; the assertions afterwards ride the context-bound `request`.
 */
async function loginThroughUi(page: import('@playwright/test').Page, email: string, tempPassword: string): Promise<void> {
	await page.goto('/Login');
	// The login form hydrates after SSR — submit before hydration reloads
	// /Login with the credentials in the URL (see rbac-scoped-grants).
	await page.waitForLoadState('networkidle', { timeout: 15_000 });
	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(tempPassword);
	await page.getByRole('button', { name: 'Sign in' }).click();

	await expect(page.getByRole('heading', { name: 'Set a new password' })).toBeVisible();
	await page.getByLabel('Current password').fill(tempPassword);
	await page.locator('input[id="input-New password"]').fill(EDITOR_PASSWORD);
	await page.getByLabel('Confirm new password').fill(EDITOR_PASSWORD);
	await page.getByRole('button', { name: 'Save password and continue' }).click();

	await expect(page).not.toHaveURL(/\/Login/);
}

test('containment: the tagged-down caller sees and writes only visible fields', async ({
	browser,
	request
}) => {
	test.setTimeout(6 * 60_000);

	let docId = '';
	let editorContext: import('@playwright/test').BrowserContext | null = null;

	// ── Arrange: domain, doctype, hidden field, row, non-admin ──────────
	await phase('arrange: the vault domain and the Ledger doctype with the confidential field', async () => {
		await postJson(
			request,
			'/Api/core/Domain',
			{
				id: DOMAIN,
				description: 'E2E containment: a field tagged confidential must never leak.',
				color: '#5E35B1'
			},
			'creating the vault domain'
		);

		await postJson(
			request,
			'/Api/core/DocType',
			{
				domain: DOMAIN,
				doctype: DOCTYPE,
				description: 'Ledger rows carry one confidential field.',
				schema_version: 1,
				display_name: '{{ name }}',
				fields: {
					[VISIBLE_FIELD]: { type: 'string', title: 'Name', required: true },
					[HIDDEN_FIELD]: {
						type: 'string',
						title: 'Secret note',
						tags: [HIDDEN_TAG]
					}
				}
			},
			'registering the Ledger doctype'
		);

		const def = await getJson(
			request,
			`/Api/core/DocType/${DOMAIN}.${DOCTYPE}`,
			'the Ledger definition'
		);
		const fields = def.data.fields as Record<string, { tags?: string[] }>;
		expect(fields[HIDDEN_FIELD].tags, 'the hidden field carries the confidential tag').toEqual([
			HIDDEN_TAG
		]);
	});

	await phase('arrange: the admin seeds a row with a value in the hidden field', async () => {
		const created = await postJson(
			request,
			`/Api/${DOMAIN}/${DOCTYPE}`,
			{
				[VISIBLE_FIELD]: VISIBLE_VALUE_INITIAL,
				[HIDDEN_FIELD]: HIDDEN_VALUE
			},
			'creating the Ledger row'
		);
		docId = String(created.meta.id);
		// The admin holds the wildcard tag — the raw value echoes back here.
		expect(created.data[HIDDEN_FIELD]).toBe(HIDDEN_VALUE);
	});

	await phase('arrange: the editor account holds the seeded editor role and a session', async () => {
		const editor = await createAccountWithRole(
			request,
			EDITOR_EMAIL,
			EDITOR_NAME,
			EDITOR_ROLE_REF
		);

		// The editor role is tagged down to `default` (`iam.Roles.editor`
		// baseline): the pinned precondition every guard below depends on.
		const role = await getJson(request, `/Api/iam/Roles/${EDITOR_ROLE_REF}`, 'the editor role');
		expect(role.data.visible_tags).toEqual(['default']);

		editorContext = await browser.newContext({ storageState: { cookies: [], origins: [] } });
		const editorPage = await editorContext.newPage();
		await loginThroughUi(editorPage, EDITOR_EMAIL, editor.tempPassword);
	});

	// The five guards, as the non-admin editor.
	const editorApi = (editorContext as unknown as import('@playwright/test').BrowserContext).request;

	// ── Guard 1: masked GET ─────────────────────────────────────────────
	await phase('guard 1: the editor GET omits the hidden field entirely', async () => {
		const read = await getJson(editorApi, `/Api/${DOMAIN}/${DOCTYPE}/${docId}`, 'the editor read');
		expect(read.data[VISIBLE_FIELD]).toBe(VISIBLE_VALUE_INITIAL);
		expect(
			read.data[HIDDEN_FIELD],
			'the hidden field must be absent from the masked read body'
		).toBeUndefined();
	});

	// ── Guard 2: masked write response ──────────────────────────────────
	await phase('guard 2: the editor PATCH response carries no hidden value', async () => {
		const patched = await patchJson(
			editorApi,
			`/Api/${DOMAIN}/${DOCTYPE}/${docId}`,
			{ [VISIBLE_FIELD]: VISIBLE_VALUE_UPDATED },
			'the editor patches the visible field'
		);
		expect(patched.data[VISIBLE_FIELD]).toBe(VISIBLE_VALUE_UPDATED);
		expect(
			patched.data[HIDDEN_FIELD],
			'the write response must not carry the hidden value back'
		).toBeUndefined();
	});

	// ── Guard 3: masked history ─────────────────────────────────────────
	await phase('guard 3: the editor history redacts create and update rows', async () => {
		const history = await getJson(
			editorApi,
			`/Api/${DOMAIN}/${DOCTYPE}/${docId}/history`,
			'the editor history'
		);
		const rows = history.data as unknown as HistoryRow[];
		expect(rows.length, 'the history carries the create and the update row').toBeGreaterThanOrEqual(2);

		const createRow = rows.find((r) => r.action === 'create');
		expect(createRow, 'the create row is in the history').toBeTruthy();
		const createContent = (createRow!.arguments.content ?? {}) as Record<string, unknown>;
		expect(createContent[VISIBLE_FIELD]).toBe(VISIBLE_VALUE_INITIAL);
		expect(
			createContent[HIDDEN_FIELD],
			'the create row must not carry the hidden value'
		).toBeUndefined();

		const updateRow = rows.find((r) => r.action === 'update');
		expect(updateRow, 'the update row is in the history').toBeTruthy();
		const diff = (updateRow!.arguments.diff ?? {}) as {
			set?: Array<{ path: string[]; value?: unknown }>;
		};
		const setEntry = (diff.set ?? []).find((entry) => entry.path.join('.') === VISIBLE_FIELD);
		expect(setEntry, 'the update diff carries the visible path').toBeTruthy();
		expect(setEntry!.value).toBe(VISIBLE_VALUE_UPDATED);

		// The removed paths land out-of-band: the create's root-hidden field
		// and nothing else (the update touched visible fields only).
		const redactedPaths = rows.flatMap((r) => (r.redacted ?? []).map((p) => p.join('.')));
		expect(redactedPaths, 'the redacted metadata names the hidden path').toContain(HIDDEN_FIELD);
	});

	// ── Guard 4: the invisible-field write refusal ──────────────────────
	await phase('guard 4: writing the hidden field is refused with 403', async () => {
		const response = await editorApi.patch(`/Api/${DOMAIN}/${DOCTYPE}/${docId}`, {
			headers: CSRF_HEADERS,
			data: { [HIDDEN_FIELD]: 'an attempt' }
		});
		expect(response.status(), 'the hidden-field write must be refused').toBe(403);
		const body = (await response.json()) as {
			error?: string;
			details?: Array<{ message?: string; code?: string }>;
		};
		expect(body.error).toBe('Write refused: invisible field');
		expect(
			(body.details ?? []).some((d) =>
				d.message?.includes(`field '${HIDDEN_FIELD}' is not visible to the active role`)
			),
			'the refusal names the hidden field'
		).toBe(true);
	});

	// ── Guard 5: the role self-escalation refusal ───────────────────────
	await phase('guard 5: adding the admin role to the own account is refused with 403', async () => {
		const me = await getJson(editorApi, '/Api/iam/me', 'the editor profile');
		const account = (me as unknown as { account: Record<string, unknown> }).account;
		const accountId = String(account.id);

		const response = await editorApi.patch(`/Api/iam/Account/${accountId}`, {
			headers: CSRF_HEADERS,
			data: { roles: [EDITOR_ROLE_REF, ADMIN_ROLE_REF] }
		});
		expect(response.status(), 'the self-escalation must be refused').toBe(403);
		const body = (await response.json()) as { error?: string };
		expect(body.error).toBe('Role authority refused this write');
	});

	await phase('teardown: close the scenario contexts', async () => {
		await editorContext?.close();
	});
});
