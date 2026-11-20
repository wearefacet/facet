// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { test, expect, type BrowserContext, type Page } from '@playwright/test';

/**
 * Platform use: the general day-two usage gate.
 * A person uses the platform for its basic job on doctypes that already exist
 * — list, sort, filter, search, create, edit, comment, delete — and observes
 * the change on a second session. Component micro-behaviour stays in
 * Storybook play functions; this file asserts journeys on the real stack.
 *
 * Actors:
 * - Editor — the default test page under the setup project's admin
 *   `storageState`. Drives every UI step.
 * - Watcher-client — a second context holding the same admin jar. Its page
 *   opens a raw `WebSocket` to `/Ws` and records every frame into
 *   `window.__wsFrames` (the pattern `rbac-scoped-grants.e2e.ts` defined);
 *   it performs no UI interaction (the SvelteKit UI holds no
 *   document-sync socket; lists and show views refresh on refetch).
 *
 * The stack seed imports the CRM bundle (stack baseline `db_reset seed:dev`),
 * which provides
 * `crm.Company` (unique `name`, enum `status`, computed `search_text`,
 * `search: "{{ name }} {{ domain_name }}"`) with its `comments` sidecar and
 * the seeded rows `crm.Company.1–3`. The scenario never authors a definition —
 * authoring has its own target (`draft-publish`).
 *
 * Pinned channel layout: a sidecar comment mutation
 * publishes only the sidecar doctype's frames — the `core.Comment` document
 * channel plus its collection channel. The host company's channels stay
 * silent: sidecars are not owned children, and the aggregate `child_changed`
 * frame skips `core` domains (`Event::Publisher.enqueue_child_changed`).
 * The comment step asserts the `core.Comment` frame pair and — with a settle
 * window — that no `crm.Company` channel carries the comment's mutation id.
 *
 * Coalescing note: the two UI edits (phone, status) fold into one mutations
 * row (same actor and channel inside the default 3-minute window), so the
 * audit trail keeps a single `update` entry — while every save still emits
 * its own `updated` frame pair, which the update step counts on the document
 * channel.
 *
 * The delete rides the show page's Actions menu (a `window.confirm` gate) and
 * tombstones the document: the live list drops the row, the trash listing
 * still shows it (retained payload), the audit trail records the delete, and
 * the watcher receives the `deleted` frame pair — the collection frame proves
 * the tombstone row passes the per-emit read check.
 */

// ── Constants ──────────────────────────────────────────────────────────────

/** Seeded `crm.Company` rows (the CRM bundle imports ids `crm.Company.1–3`). */
const ACME_NAME = 'Acme Corp';
const GLOBEX_NAME = 'Globex Inc';
const INITECH_NAME = 'Initech';

/** The company the scenario creates, edits, comments on, and deletes. */
const NEW_COMPANY_NAME = 'Platform Use Co';
const NEW_COMPANY_PHONE = '+1-555-0310';
const UPDATED_COMPANY_PHONE = '+1-555-0311';
const NEW_COMPANY_DOMAIN = 'platformuse.example';

/** The comment the editor posts through the sidecar composer. */
const COMMENT_TEXT = 'Watcher probe: posted from the composer.';

/** The list table's search box (FilterBar). */
const SEARCH = { placeholder: 'Search…' } as const;

/** Time the WS negative assertion waits after the comment mutation. */
const WS_SETTLE = 4_000;

// ── Helpers ────────────────────────────────────────────────────────────────

/** Logs each phase before running it: the list reporter stays silent until a
 * test finishes, so a long phase must say its name or a slow run is
 * indistinguishable from a hang. */
async function phase(name: string, body: () => Promise<void>): Promise<void> {
	console.log(`\n[${new Date().toISOString().slice(11, 19)}] >> ${name}`);
	await test.step(name, body);
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

/** Reads every frame the watcher-client has recorded so far. */
async function framesOf(wsPage: Page): Promise<WsFrame[]> {
	return wsPage.evaluate(() => (window as WsWindow).__wsFrames ?? []);
}

// ── The scenario ───────────────────────────────────────────────────────────

test('platform use: list, filter, search, create, edit, comment, delete, live fan-out', async ({
	page,
	browser,
	request
}) => {
	test.setTimeout(9 * 60_000);

	let newCompanyId = '';
	let adminAccountId = '';
	let adminDisplayName = '';
	let wsContext: BrowserContext | null = null;
	let wsPage: Page | null = null;

	// ── 1. The seeded list renders and sorts (step 1) ───────────────────
	await phase('list: the seeded companies render and sort by name', async () => {
		await page.goto('/crm/Company');
		await expect(companyRow(page, ACME_NAME)).toBeVisible();
		await expect(companyRow(page, GLOBEX_NAME)).toBeVisible();
		await expect(companyRow(page, INITECH_NAME)).toBeVisible();

		// The seeded "All Records" view's first column is `name`
		// ("Company Name"). The first header click sorts ascending.
		const nameHeader = page.getByRole('columnheader', { name: 'Company Name' });
		await nameHeader.click();
		await expect(nameHeader).toHaveAttribute('aria-sort', 'ascending');
		const rows = page.locator('tbody tr');
		await expect(rows.nth(0)).toContainText(ACME_NAME);
		await expect(rows.nth(1)).toContainText(GLOBEX_NAME);
		await expect(rows.nth(2)).toContainText(INITECH_NAME);
	});

	// ── 2. Enum equality filter (step 2) ────────────────────────────────
	await phase('filter: status = lead narrows the table and clearing restores it', async () => {
		// "Add filter" → the Status entry adds an `is` chip with an empty
		// value; the chip's value control is its second combobox (the
		// operator dropdown sits first). The menu item's `onSelect` handler
		// prevents default, so Bits UI keeps the menu's focus-trap overlay
		// mounted until focus settles — press Escape to dismiss it before
		// interacting with the chip.
		await page.getByRole('button', { name: '+ Add filter' }).click();
		await page.getByRole('menuitem', { name: 'Status' }).click();
		await page.keyboard.press('Escape');

		const chip = page.locator('.chip.act', { hasText: 'Status' });
		await chip.locator('.select-field-input').nth(1).click();
		await page.getByRole('option', { name: 'Lead' }).click();

		// Globex and Initech are seeded leads; Acme is active.
		await expect(companyRow(page, GLOBEX_NAME)).toBeVisible();
		await expect(companyRow(page, INITECH_NAME)).toBeVisible();
		await expect(companyRow(page, ACME_NAME)).toHaveCount(0);

		await chip.getByRole('button', { name: 'Remove filter' }).click();
		await expect(companyRow(page, ACME_NAME)).toBeVisible();
	});

	// ── 3. Trigram search over the computed corpus (step 3) ─────────────
	await phase('search: the search corpus matches one company and empties on a miss', async () => {
		const search = page.getByPlaceholder(SEARCH.placeholder);
		// The `search` column concatenates name and domain ("Globex Inc
		// globex.com") — a substring of either matches.
		await search.fill('globex');
		await expect(companyRow(page, GLOBEX_NAME)).toBeVisible();
		await expect(companyRow(page, ACME_NAME)).toHaveCount(0);
		await expect(companyRow(page, INITECH_NAME)).toHaveCount(0);

		await search.fill('no-such-company-xyz');
		await expect(page.getByRole('row', { name: 'No records' })).toBeVisible();

		await search.fill('');
		await expect(companyRow(page, ACME_NAME)).toBeVisible();
	});

	// ── 4. Create through the form, duplicate rejected (step 4) ─────────
	await phase('create: a duplicate name is rejected, then the form creates the company', async () => {
		await page.getByRole('button', { name: 'New', exact: true }).click();
		await expect(page).toHaveURL(/\/crm\/Company\/new$/);

		// Sad path in the same step: the seeded unique name fails the
		// unique constraint with a field-scoped 422.
		await page.getByLabel('Company Name').fill(ACME_NAME);
		await page.getByRole('button', { name: 'Create', exact: true }).click();
		// The UI renders the structured 422 through the validation catalogue
		// (code `unique`), not the backend's raw message text.
		await expect(page.locator('.alert-banner')).toContainText('already in use');
		await expect(page.locator('.field-err', { hasText: 'This value is already in use.' })).toBeVisible();

		await page.getByLabel('Company Name').fill(NEW_COMPANY_NAME);
		await page.getByLabel('Phone Number').fill(NEW_COMPANY_PHONE);
		// The template-driven form labels `domain_name` "Domain" (not the
		// doctype field's "Domain Name" title — the authored form template
		// owns the label).
		await page.getByLabel('Domain', { exact: true }).fill(NEW_COMPANY_DOMAIN);
		await page.getByRole('button', { name: 'Create', exact: true }).click();

		// Success lands on the show route of the fresh ULID id.
		await expect(page).not.toHaveURL(/\/new$/);
		newCompanyId = page.url().split('/').pop() ?? '';
		expect(newCompanyId, 'the create lands on the show route of the new document').toBeTruthy();

		// The row joins the list on refetch.
		await page.goto('/crm/Company');
		await expect(companyRow(page, NEW_COMPANY_NAME)).toBeVisible();
	});

	// ── 5. The watcher-client subscribes (step 5) ───────────────────────
	await phase('watcher: the scripted client subscribes the crm and comment channels', async () => {
		// The admin identity for the actioner_id header assertion and the
		// comment-author label. The profile route writes a bare payload —
		// no {data, meta} envelope.
		const meResponse = await request.get('/Api/iam/me');
		expect(meResponse.ok(), 'the admin profile read must succeed').toBe(true);
		const me = (await meResponse.json()) as {
			account: { id: string; display_name: string };
		};
		adminAccountId = me.account.id;
		adminDisplayName = me.account.display_name;
		expect(adminAccountId, 'the profile names the account id').toBeTruthy();

		// Context B holds the same session under a fresh jar.
		wsContext = await browser.newContext({
			storageState: await page.context().storageState()
		});
		const watcher = await wsContext.newPage();
		wsPage = watcher;
		await watcher.goto('/');
		await expect(watcher).not.toHaveURL(/\/Login/);

		await watcher.evaluate((docId) => {
			const w = window as WsWindow;
			w.__wsFrames = [];
			w.__wsState = 'connecting';
			const ws = new WebSocket(`wss://${window.location.host}/Ws`);
			ws.onopen = () => {
				w.__wsState = 'open';
				// The company collection path (per-emit RBAC filter), the new
				// company's document path, and the comment sidecar's
				// collection path. A sidecar mutation publishes only its own
				// doctype's frames — pinned in the comment step below.
				ws.send(
					JSON.stringify({
						action: 'subscribe',
						args: ['/crm/Company', `/crm/Company/${docId}`, '/core/Comment']
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
		}, newCompanyId);

		await expect
			.poll(() => watcher.evaluate(() => (window as WsWindow).__wsState), {
				message: 'the socket upgrade must succeed'
			})
			.toBe('open');

		// No ack exists for a subscribe — a denial would arrive as an error
		// frame. A short beat proves all three subscriptions were accepted
		// (the admin ceiling holds read on each channel).
		await watcher.waitForTimeout(800);
		const early = await framesOf(watcher);
		expect(
			early.filter((f) => f.error !== undefined),
			'no subscribe-time error frame may arrive'
		).toEqual([]);

		// The editor's show view renders the created document's fields — the
		// bundle's authored `view` template (Contact section). The phone
		// renders inside its Copy capsule.
		await page.goto(`/crm/Company/${newCompanyId}`);
		await expect(page.getByRole('heading', { name: NEW_COMPANY_NAME })).toBeVisible();
		await expect(page.getByRole('button', { name: `Copy ${NEW_COMPANY_PHONE}` })).toBeVisible();
	});

	// ── 6. Edit a field, show + list reflect, history one update
	//      (step 6) ─────────────────────────────────────────────────────
	await phase('edit: the phone change lands on show and list; history records one update', async () => {
		await page.getByRole('button', { name: 'Edit' }).click();
		await expect(page).toHaveURL(/\/edit$/);
		await page.getByLabel('Phone Number').fill(UPDATED_COMPANY_PHONE);
		await page.getByRole('button', { name: 'Save', exact: true }).click();
		await expect(page).not.toHaveURL(/\/edit$/);
		await expect(page.getByRole('button', { name: `Copy ${UPDATED_COMPANY_PHONE}` })).toBeVisible();

		await page.goto('/crm/Company');
		await expect(companyRow(page, NEW_COMPANY_NAME)).toContainText(UPDATED_COMPANY_PHONE);

		// The mutation history holds one create and one update. The later
		// status edit folds into this update row (same actor and channel
		// inside the coalesce window), so the count stays at one.
		await page.goto(`/crm/Company/${newCompanyId}/history`);
		await expect(page.locator('.audit-action', { hasText: 'Created' })).toHaveCount(1);
		await expect(page.locator('.audit-action', { hasText: 'Updated' })).toHaveCount(1);
	});

	// ── 7. Status change fans out (step 7) ──────────────────────────────
	await phase('ws update: the status change fans out updated frames on both channels', async () => {
		await page.goto(`/crm/Company/${newCompanyId}`);
		await page.getByRole('button', { name: 'Edit' }).click();
		const status = page.getByLabel('Status');
		await status.click();
		await page.getByRole('option', { name: 'Active' }).click();
		await page.getByRole('button', { name: 'Save', exact: true }).click();
		await expect(page).not.toHaveURL(/\/edit$/);
		// The authored view template renders the status enum as a capsule
		// with the humanized label.
		await expect(page.getByText('Active', { exact: true })).toBeVisible();

		// Each save emits one frame pair. The watcher has been subscribed
		// since the watcher phase, so the document channel now carries both
		// edits' frames; the second is the status change.
		const watcher = wsPage as Page;
		let statusFrame: WsFrame | undefined;
		await expect
			.poll(async () => {
				const frames = (await framesOf(watcher)).filter(
					(f) => f.channel === `fanout:crm.Company:${newCompanyId}:updated`
				);
				statusFrame = frames[1];
				return frames.length;
			})
			.toBe(2);

		expect(statusFrame?.event).toBe('updated');
		expect(statusFrame?.payload?.id).toBe(newCompanyId);
		expect(statusFrame?.headers?.domain).toBe('crm');
		expect(statusFrame?.headers?.doc_type).toBe('Company');
		expect(statusFrame?.headers?.actioner_id).toBe(adminAccountId);
		expect(String(statusFrame?.headers?.mutation_id ?? '')).toBeTruthy();

		// The collection channel delivered the same mutations too (the
		// admin passes the per-emit read check).
		const frames = await framesOf(watcher);
		expect(
			frames.filter((f) => f.channel === 'fanout:crm.Company:updated' && f.payload?.id === newCompanyId)
				.length,
			'the collection channel carries one updated frame per save'
		).toBe(2);
	});

	// ── 8. Comment through the sidecar composer (step 8) ────────────────
	await phase('comment: the composer posts the comment under the editor identity', async () => {
		await page.goto(`/crm/Company/${newCompanyId}`);
		const composer = page.getByTestId('comment-composer');
		await expect(composer).toBeVisible();
		await composer.locator('.ProseMirror').click();
		await page.keyboard.type(COMMENT_TEXT);
		await composer.getByRole('button', { name: 'Comment' }).click();

		// The panel reloads its thread after the POST; the author label
		// resolves because the editor can read its own account (the backend
		// forces the author — the composer submits the body only).
		await expect(page.locator('.cs-thread')).toContainText(COMMENT_TEXT);
		await expect(page.locator('.cs-thread')).toContainText(adminDisplayName);
	});

	// ── 9. The sidecar mutation's channels (step 9, pinned) ─────────────
	await phase('ws sidecar: the comment rides only the core.Comment channels', async () => {
		const watcher = wsPage as Page;
		let commentFrame: WsFrame | undefined;
		await expect
			.poll(async () => {
				const frames = await framesOf(watcher);
				commentFrame = frames.find((f) => f.channel === 'fanout:core.Comment:created');
				return commentFrame;
			})
			.not.toBeFalsy();

		expect(commentFrame?.event).toBe('created');
		const commentId = String(commentFrame?.payload?.id ?? '');
		expect(commentId, 'the comment frame names the comment document').toBeTruthy();
		expect(commentFrame?.headers?.domain).toBe('core');
		expect(commentFrame?.headers?.doc_type).toBe('Comment');
		expect(commentFrame?.headers?.actioner_id).toBe(adminAccountId);
		const commentMutationId = String(commentFrame?.headers?.mutation_id ?? '');
		expect(commentMutationId).toBeTruthy();

		// Pinned channel layout: the host company's
		// channels stay silent — sidecars are not owned children and the
		// aggregate child_changed frame skips core domains.
		await watcher.waitForTimeout(WS_SETTLE);
		const settled = await framesOf(watcher);
		expect(
			settled.filter(
				(f) =>
					f.channel?.startsWith('fanout:crm.Company') &&
					f.headers?.mutation_id === commentMutationId
			),
			'no crm.Company channel may carry the comment mutation'
		).toEqual([]);
	});

	// ── 10. Delete through the Actions menu (step 10) ───────────────────
	await phase('delete: the tombstone leaves the live list and shows in trash', async () => {
		await page.goto(`/crm/Company/${newCompanyId}`);

		// Delete is demoted into the Actions menu behind a confirm gate.
		// Playwright auto-dismisses dialogs — the accept handler must be
		// registered before the click. The Actions button is a single native
		// <button> that is its own menu trigger (the Button `menu` mode — a
		// nested Trigger inside it would emit <button><button> and break SSR
		// hydration; see doc/frontend/bits-ui.md).
		page.once('dialog', (dialog) => dialog.accept());
		// Exact: the top-bar search button's label contains the word actions.
		await page.getByRole('button', { name: 'Actions', exact: true }).click();
		await page.getByRole('menuitem', { name: 'Delete' }).click();
		await expect(page).toHaveURL(/\/crm\/Company$/);

		// The live list drops the tombstoned row on refetch.
		await expect(companyRow(page, NEW_COMPANY_NAME)).toHaveCount(0);

		// The trash listing still carries it — the tombstone retains its
		// payload (display_name included) until the prune window passes.
		// Asserted by URL param (the toggle's own contract) plus the row.
		await page.getByRole('button', { name: 'Deleted', exact: true }).click();
		await expect(page).toHaveURL(/deleted=true/);
		await expect(companyRow(page, NEW_COMPANY_NAME)).toBeVisible();

		// The audit trail records the delete (the history route reads the
		// tombstoned document's mutations).
		await page.goto(`/crm/Company/${newCompanyId}/history`);
		await expect(page.locator('.audit-action', { hasText: 'Deleted' })).toBeVisible();
	});

	// ── 11. The deleted frame pair (step 11) ────────────────────────────
	await phase('ws delete: the tombstone fans out deleted frames', async () => {
		const watcher = wsPage as Page;
		let deletedFrame: WsFrame | undefined;
		await expect
			.poll(async () => {
				const frames = await framesOf(watcher);
				deletedFrame = frames.find((f) => f.channel === `fanout:crm.Company:${newCompanyId}:deleted`);
				return deletedFrame;
			})
			.not.toBeFalsy();

		expect(deletedFrame?.event).toBe('deleted');
		expect(deletedFrame?.payload?.id).toBe(newCompanyId);
		expect(deletedFrame?.headers?.domain).toBe('crm');
		expect(deletedFrame?.headers?.doc_type).toBe('Company');
		expect(String(deletedFrame?.headers?.mutation_id ?? '')).toBeTruthy();

		// The collection channel delivered the delete too: the per-emit
		// read check scopes the tombstone row, whose retained payload
		// passes under the admin session.
		const frames = await framesOf(watcher);
		expect(
			frames.some(
				(f) => f.channel === 'fanout:crm.Company:deleted' && f.payload?.id === newCompanyId
			),
			'the collection channel carries the tombstoned document too'
		).toBe(true);
	});

	// ── Teardown of the manual context ──────────────────────────────────
	await phase('teardown: close the watcher context', async () => {
		await wsContext?.close();
	});
});
