// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { test, expect, type APIRequestContext, type Page } from '@playwright/test';

/**
 * Draft domains, publish and replication: the definition-authoring loop
 * end to end — a draft is cut from the live `crm` domain, its copied doctypes
 * are authored, replication stays inert while it is a draft, and publish turns
 * the draft into the live domain `crmdraft`, after which the declared edge
 * flows under the grant ticket the publish filed.
 *
 * UI paths this file pins (drive what the app actually has):
 * - Draft creation is the Builder sidebar's "Edit existing" dialog (the
 *   `EditDomainDialog`): pick the live domain row, click its Edit button —
 *   the app POSTs `/Api/core/Domain/{id}/draft` and lands on
 *   `/Builder/{_draftId}/overview`.
 * - The draft grid lives on the `/Builder` landing; drafts from a live
 *   source are labelled `{Source label} (draft)` by `domainProjectionTo`.
 * - The doctype grid is the DomainEditor's Doctypes tab; a row click opens
 *   the doctype editor at `/Builder/{draft}/{Doctype}/fields`.
 * - Preview mode is entered through the `/Builder/{draft}/preview` entry
 *   page: it issues a `typ: preview` capability
 *   token, stages it in the preview store, and lands on the draft's live
 *   URL (`/{_draftId}`) under the PreviewBanner; Exit returns to the
 *   editor overview. (The BuilderModeBar's Preview toggle is racy — it
 *   sets the token while the URL is still the editor tab, which the root
 *   layout's preview-lifecycle effect treats as "navigated away" and
 *   clears; see the final report on the run.)
 * - Publish is the BuilderModeBar Publish pill → the PublishDialog (target
 *   name input). When the backend answers 409 (target name taken), the
 *   dialog swaps the form for an explicit overwrite confirmation; clicking
 *   "Publish over {name}" re-sends with `overwrite: true`. The same dialog
 *   drives the fresh publish (§4 step 6) and the overwrite publish through
 *   the version gate (§4 step 8).
 * - A publish whose draft declares outbound cross-domain edges ends on the
 *   dialog's ticket report (Publish tickets from the edges automatically):
 *   one card per producer — "from {producer}", the filed/merged line, the
 *   `{doctype}: {tags}` edge list, the Active/Awaiting state, and the
 *   untagged-fields warning — and a "Go to {domain}" button as the only
 *   exit. The scenario leaves the report through that button and asserts
 *   the card's content.
 *
 * The admin scenario pins the D11 fast path: the seeded admin holds the
 * `activate` named action on `core.DomainGrant`, so the tickets the publish
 * files land **active** — no producer-side acceptance step. The ticket
 * report asserts that state; the producer-subtree read asserts the stored
 * grant document (`active` is read-only on the wire — the routes and the
 * publish filing set it).
 *
 * What the UI cannot author (and how this file compensates):
 * - `DoctypeFieldEditor` models Key/Type/Title and nothing else; the
 *   `replicate` config has no editor widget, and `migrations` is
 *   preserved verbatim by `serializeDoctypeDef` (never authored). So the
 *   replicate declaration (§4 step 4) and both gate passages (version bump +
 *   a no-op migration — the first publish's gate and the step-8 overwrite
 *   gate) ride the draft-mode authoring API
 *   (`PUT /Api/core/DocType/{draft}.{Doctype}`), which `Doctype::Update`
 *   accepts freely while the domain is a draft. The same PUT re-points the
 *   draft's `company_id` at the live producer: the structure copy relinks
 *   every same-domain reference target to the draft identity
 *   (`doc/backend/draft-domains.md`), so the replication edge would stay
 *   intra-draft (inert, no grant needed) unless the authoring deliberately
 *   un-relinks it. Everything else — draft creation, field authoring,
 *   preview, both publishes — goes through the UI; the API also carries the
 *   arrangement (consumer documents, source mutations) arranged through the
 *   API, not the UI.
 *
 * Replication shape pinned per `doc/backend/replication.md`: a
 * `replicate` field is `{via, field}` — `via` names a `reference`-typed
 * field on the same doctype, `field` names the source field. The consumer
 * must reference the source document explicitly: reference values are
 * stored fully qualified (`crm.Company.{id}`), which is what
 * `Replication::Queries` matches against the source event's id.
 *
 * Step 9 is the file's only async assertion: poll the consumer docs'
 * replica fields until the handler's write lands or the deadline hits
 * (a timeout is a failure, not a retry). The initial
 * replica value is written synchronously by `SyncPull` at create time, so
 * the polls observe the later event-driven `Replication::Handler` path.
 */

// ── Constants ──────────────────────────────────────────────────────────────

/** The live source domain (the CRM bundle imported by the stack baseline). */
const SOURCE = 'crm';

/** The publish target the scenario owns (fresh in step 6, overwritten in 8). */
const TARGET = 'crmdraft';

/**
 * Step 7 authors its own source company over the API; the consumers then
 * reference it as `crm.Company.{ulid}`. The bundle's seeded company cannot
 * serve here: the seeded documents carry dotted opaque ids (`crm.Company.1`),
 * and the consumer-side lookup (`Replication::SyncPull` source read,
 * `Replication::Queries.referencing_docs`) does not resolve that id form.
 * A fresh document gets a plain ULID id — the one id form the edge resolves.
 * Backend defect; see the run report.
 */
const SOURCE_NAME_INITIAL = 'Mehvex Base';

/** The later source names the events must land (`activate`, then epilogue). */
const SOURCE_NAME_UPDATED = 'Mehvex Industrial';
const SOURCE_NAME_FINAL = 'Mehvex Worldwide';

/** The source field the replicate edge watches. */
const SOURCE_FIELD = 'name';

/** The producer doctype the filed grant must name. */
const PRODUCER_DOCTYPE = 'Company';

/** The tag the ticket claims: the source field is untagged (→ `default`). */
const DEFAULT_TAG = 'default';

/**
 * The stage the step-7 consumer Deal points at, created in the published
 * domain: the structure copy relinks same-domain reference targets
 * (`doc/backend/draft-domains.md`), so the published Deal's `stage_id`
 * declares `crmdraft.PipelineStage` — a doctype the publish ships empty.
 */
const DEAL_STAGE_NAME = 'E2E replication stage';

/** The consumer docs created against the published domain (stack seed data). */
const DEAL_TITLE = 'E2E replication deal';
const DEAL_VALUE = { value: '6500', currency: 'USD' };

/** The field added to the draft's Deal copy in §4 step 3 (plain UI authoring). */
const ADDED_FIELD = 'tie_breaker';

/** The replicate field declared on the draft's Deal copy in §4 step 4. */
const REPLICA_FIELD = 'company_name';

/**
 * The version the first publish's gate demands for the structurally changed
 * draft Deal (live `crm.Deal` is 1; `schema_version` must be live + 1 and the
 * migration gap must carry an entry).
 */
const FIRST_GATE_VERSION = 2;

/**
 * The version the step-8 overwrite gate demands: the first publish landed
 * `crmdraft.Deal` at `FIRST_GATE_VERSION`, so the fresh (unedited-fields)
 * draft must carry live + 1 with its own migration entry.
 */
const GATE_VERSION = FIRST_GATE_VERSION + 1;

/**
 * The CSRF surface for scripted JSON writes (same contract as
 * app-head-to-toe): the `X-Requested-With` header
 * (`HTTP::Helpers.require_csrf`), not cookies or tokens.
 */
const CSRF_HEADERS = { 'X-Requested-With': 'XMLHttpRequest' };

/** Poll deadline for the one async assertion (Replication::Handler, event-driven). */
const REPLICATION_SETTLE = 45_000;

// ── Types ──────────────────────────────────────────────────────────────────

/** One edge of a publish ticket (mirrors the backend `Grants::PublishTickets::Filing`). */
interface TicketEdge {
	doctype: string;
	tags: string[];
}

/** One producer's ticket outcome (mirrors `Grants::PublishTickets::Ticket`). */
interface GrantTicket {
	producer: string;
	filed: boolean;
	active: boolean;
	dropped: boolean;
	edges: TicketEdge[];
}

/** The publish response's grant-ticket report (`Publish::Result.grant_tickets`). */
interface PublishReport {
	domain: string;
	grant_tickets: GrantTicket[];
}

// ── Helpers ────────────────────────────────────────────────────────────────

/** Logs each phase before running it: the list reporter stays silent until a
 * test finishes, so a long phase must say its name or a slow run is
 * indistinguishable from a hang. */
async function phase(name: string, body: () => Promise<void>): Promise<void> {
	console.log(`\n[${new Date().toISOString().slice(11, 19)}] >> ${name}`);
	await test.step(name, body);
}

/** Extracts the `_`-prefixed draft id from a `/Builder/{draft}/…` URL. */
function draftIdFromUrl(url: string): string {
	const match = url.match(/\/Builder\/(_[^/]+)/);
	if (!match) throw new Error(`not a Builder draft URL: ${url}`);
	return match[1];
}

/** GETs a JSON document and asserts the round trip succeeded. */
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

/** PATCHes JSON and asserts the write landed (CSRF-checked route). */
async function patchJson(
	request: APIRequestContext,
	path: string,
	data: Record<string, unknown>,
	message: string
): Promise<Record<string, unknown>> {
	const response = await request.patch(path, { headers: CSRF_HEADERS, data });
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 400)}`
	).toBe(true);
	return JSON.parse(body);
}

/**
 * Re-points one reference field of a copied definition at a cross-domain
 * target. The structure copy relinks every same-domain reference target to
 * the draft identity (`doc/backend/draft-domains.md`); the replication edge
 * needs a reference that keeps pointing at the live producer, so the draft
 * authoring deliberately un-relinks it.
 */
function repointReference(
	definition: Record<string, unknown>,
	fieldName: string,
	target: string
): Record<string, unknown> {
	const fields = definition.fields as Record<string, Record<string, unknown>>;
	const field = fields[fieldName];
	expect(field, `the copied definition carries the '${fieldName}' field`).toBeTruthy();
	return {
		...definition,
		fields: { ...fields, [fieldName]: { ...field, doctype: target } }
	};
}

/**
 * Appends a no-op migration `migrate_from_{n}` to a doctype Lua script (a
 * no-op Lua migration is acceptable per doc/backend/draft-domains.md) — the
 * version gate demands an entry for every migration gap.
 */
function withMigrationFn(script: string, fromVersion: number): string {
	const fn = `function export.migrate_from_${fromVersion}(ctx) end`;
	return script.includes('return export')
		? script.replace(/return\s+export\s*$/, `${fn}\n\nreturn export`)
		: `${script}\n${fn}`;
}

/** PUTs the full doctype definition (draft-mode authoring) and asserts 200. */
async function putDoctypeDefinition(
	request: APIRequestContext,
	qualifiedId: string,
	definition: Record<string, unknown>,
	message: string
): Promise<Record<string, unknown>> {
	const response = await request.put(`/Api/core/DocType/${encodeURIComponent(qualifiedId)}`, {
		headers: CSRF_HEADERS,
		data: definition
	});
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 600)}`
	).toBe(true);
	return JSON.parse(body);
}

/** Reads one document (lazy migration included) and returns its content. */
async function readDoc(
	request: APIRequestContext,
	domain: string,
	doctype: string,
	id: string
): Promise<Record<string, unknown>> {
	const body = await getJson(
		request,
		`/Api/${domain}/${doctype}/${id}`,
		`${domain}.${doctype}/${id}`
	);
	return body.data;
}

/** Creates a document and returns { id, content } from the response. */
async function createDoc(
	request: APIRequestContext,
	domain: string,
	doctype: string,
	content: Record<string, unknown>,
	message: string
): Promise<{ id: string; content: Record<string, unknown> }> {
	const response = await request.post(`/Api/${domain}/${doctype}`, {
		headers: CSRF_HEADERS,
		data: content
	});
	const body = await response.text();
	expect(
		response.ok(),
		`${message} must succeed (HTTP ${response.status()}): ${body.slice(0, 400)}`
	).toBe(true);
	const parsed = JSON.parse(body) as {
		data: Record<string, unknown>;
		meta: { id: string };
	};
	return { id: parsed.meta.id, content: parsed.data };
}

/**
 * Lists the grant documents under one producer domain: `core.DomainGrant`
 * rows whose `meta.parent_id` is the producer's bare domain id, filtered to
 * one consumer. The flat list route exposes `meta.parent_id` on every row
 * (the shape `DomainGrantsTab` relies on for the held-access rows).
 */
async function listProducerGrants(
	request: APIRequestContext,
	producer: string,
	consumer: string
): Promise<
	Array<{
		id: string;
		content: Record<string, unknown>;
		meta: Record<string, unknown>;
	}>
> {
	const body = await getJson(
		request,
		`/Api/core/DomainGrant?consumer_domain__eq=${encodeURIComponent(`core.Domain.${consumer}`)}`,
		`the grant list filtered to the ${consumer} consumer`
	);
	// The collection wire shape is { data, meta } per row — the document id
	// rides `meta.id`.
	const rows = ((body.data as unknown) ?? []) as Array<{
		data: Record<string, unknown>;
		meta: Record<string, unknown> & { id?: string };
	}>;
	return rows
		.filter((row) => row.meta.parent_id === producer)
		.map((row) => ({
			id: String(row.meta.id),
			content: row.data,
			meta: row.meta
		}));
}

/**
 * Drives the "Edit existing domain" dialog on the Builder: opens the
 * sidebar trigger, clicks the live domain's Edit row, and resolves once the
 * app has POSTed the draft and landed on the new draft's overview — the
 * URL carries the autogenerated draft id, which is how the scenario keeps
 * talking to the right draft afterwards.
 *
 * The row is matched on the label node (`{ hasText: domainLabel }` inside a
 * listitem whose first generic is the name) — strict-mode note: `filter({
 * hasText: 'CRM' })` alone also matches the `Crmdraft` row (substring), so
 * the anchor is the exact-name generic, not the whole row.
 */
async function draftFromLiveDomain(page: Page, domainLabel: string): Promise<string> {
	await page.goto('/Builder');
	await page.getByRole('button', { name: 'Edit existing' }).click();
	const dialog = page.getByRole('dialog');
	await expect(dialog.getByText('Edit existing domain')).toBeVisible();
	await dialog
		.getByRole('listitem')
		.filter({ has: page.getByText(domainLabel, { exact: true }) })
		.getByRole('button', { name: 'Edit' })
		.click();
	await expect(page).toHaveURL(/\/Builder\/_[^/]+\/overview$/, {
		timeout: 20_000
	});
	return draftIdFromUrl(page.url());
}

/**
 * Opens the DomainEditor's Doctypes tab and returns its copied-doctype row
 * count from the "Doctypes (n)" heading — the copy proof for
 * `Domain::Copy.structure`.
 */
async function openDoctypesTab(page: Page, expectCount: number): Promise<void> {
	await page
		.getByRole('button', { name: /Doctypes/ })
		.first()
		.click();
	await expect(page.getByText(`Doctypes (${expectCount})`)).toBeVisible();
}

/**
 * Publishes the active draft through the BuilderModeBar pill + dialog under
 * `target`. Resolves with the publish outcome: `null` when the dialog closed
 * on success with no grant tickets, or the ticket report when the publish
 * filed or merged grant tickets — the dialog then stays open on the report
 * and the caller leaves it through `continueFromReport`.
 */
async function publishViaDialog(page: Page, target: string): Promise<PublishReport | null> {
	await page
		.getByRole('button', { name: /^Publish/ })
		.first()
		.click();
	const dialog = page.getByRole('dialog');
	await expect(dialog.getByText('Publish draft domain')).toBeVisible();

	// The dialog seeds its input from the draft snapshot's publish name on
	// open (source-domain fallback), so the prefill lands within a beat of
	// the title. Waiting for a non-empty value first keeps the fill from
	// racing the seed.
	const nameInput = page.getByLabel('Target domain name');
	await expect(nameInput).not.toHaveValue('', { timeout: 20_000 });
	await nameInput.fill(target);
	await expect(nameInput).toHaveValue(target);

	await dialog.getByRole('button', { name: /^Publish/ }).click();
	const reportTitle = dialog.getByText('Domain published');

	// Two success shapes: no grant tickets → the dialog closes (the caller
	// navigates itself); tickets → the dialog stays open on the ticket
	// report. Resolve which one landed instead of guessing — the store's
	// post-publish `goto` can lose the race with the `clearBuilderDraft`
	// re-render, so closing is observed, not assumed. Both probes poll to a
	// settled verdict; the first match wins (the dialog cannot close and
	// report at once).
	const closed = expect(async () => {
		expect(await dialog.isVisible()).toBe(false);
	}).toPass({ timeout: 60_000 });
	const reported = expect(async () => {
		expect(await reportTitle.isVisible()).toBe(true);
	}).toPass({ timeout: 60_000 });
	const [closeOutcome, reportOutcome] = await Promise.allSettled([closed, reported]);
	const didClose = closeOutcome.status === 'fulfilled';
	const didReport = reportOutcome.status === 'fulfilled';

	if (didReport) {
		// The report renders one card per producer; read the state from the
		// DOM so a failed D11 verdict fails here with the rendered text.
		expect(didClose, 'the dialog must stay open on the ticket report').toBe(false);
		const cards = dialog.locator('.ticket');
		const producers = await cards.locator('.ticket-producer').allTextContents();
		const states = await cards.locator('.ticket-state').allTextContents();
		const kinds = await cards.locator('.ticket-kind').allTextContents();
		const tickets: GrantTicket[] = [];
		for (const [i, producerLabel] of producers.entries()) {
			tickets.push({
				producer: producerLabel.replace(/^from\s+/, ''),
				filed: /New grant filed/.test(kinds[i] ?? ''),
				active: /Active/.test(states[i] ?? ''),
				dropped: false,
				edges: await readTicketEdges(cards, i)
			});
		}
		return { domain: target, grant_tickets: tickets };
	}

	expect(
		didClose,
		'the dialog must close on a publish with no grant tickets (or show the report)'
	).toBe(true);
	return null;
}

/** Reads one report card's `{doctype}: {tags}` edge rows. */
async function readTicketEdges(
	cards: ReturnType<Page['locator']>,
	index: number
): Promise<TicketEdge[]> {
	const raw = await cards.nth(index).locator('.edge').allTextContents();
	return raw.map((line) => {
		const [doctype, tagsPart] = line.split(':');
		return {
			doctype: (doctype ?? '').trim(),
			tags: (tagsPart ?? '')
				.split(',')
				.map((t) => t.trim())
				.filter((t) => t.length > 0)
		};
	});
}

/** Leaves the publish dialog's ticket report through its "Go to {domain}"
 * button — the report's only exit; the receiver navigates. */
async function continueFromReport(page: Page, domain: string): Promise<void> {
	const dialog = page.getByRole('dialog');
	await dialog.getByRole('button', { name: `Go to ${domain}` }).click();
	await expect(dialog).not.toBeVisible();
}

// ── The scenario ───────────────────────────────────────────────────────────

test('draft and publish: draft from crm, replicate inert, publish, edge flows, overwrite', async ({
	page,
	request
}) => {
	test.setTimeout(9 * 60_000);

	let draftId = '';
	let dealId = '';
	let customerId = '';
	let sourceCompanyId = '';
	let sourceCompanyRef = '';

	// ── 1. Draft from crm (§4 step 1) ───────────────────────────────────
	await phase('draft: the admin drafts the live crm domain from the Builder', async () => {
		draftId = await draftFromLiveDomain(page, 'CRM');
	});

	await phase(
		'draft: the draft grid shows the draft; its domain doc carries draft=true',
		async () => {
			// The Builder landing's draft grid derives from `buildNavModel({drafts:
			// true})`; a draft from crm is labelled "CRM (draft)".
			await page.goto('/Builder');
			await expect(page.locator('.draft-card').filter({ hasText: 'CRM (draft)' })).toBeVisible();

			// The boolean flag — not the `_` prefix — is the source of truth for
			// every isolation decision (doc/backend/draft-domains.md → Naming).
			const body = await getJson(request, `/Api/core/Domain/${draftId}`, 'the draft domain show');
			expect(body.data.draft).toBe(true);
			expect(body.data.source_domain).toBe(SOURCE);
		}
	);

	// ── 2. Copied definitions + preview (§4 step 2) ─────────────────────
	await phase('copy: the draft editor lists the copied crm definitions', async () => {
		await page.goto(`/Builder/${draftId}/overview`);
		await expect(page.getByText('from crm')).toBeVisible();

		// The CRM bundle defines exactly eight doctypes; the copy carried all
		// of them (structure only — no document data). Row names carry the
		// root/child badges ("Company root 1 child"), so anchor on the
		// doctype name — "/^Company/" alone would also match CompanyMembership.
		await openDoctypesTab(page, 8);
		await expect(page.locator('.dt-list .dt-row').first()).toBeVisible();
		await expect(page.getByRole('button', { name: /^Company root/ })).toBeVisible();
		await expect(page.getByRole('button', { name: /^Customer root/ })).toBeVisible();
	});

	await phase('preview: the draft browses under the preview principal', async () => {
		// The entry seam for preview is the /Builder/{draft}/preview wildcard
		// page: it issues the `typ: preview` capability token, stages it in
		// the preview store (cookie mirrored for F5), and forwards to the
		// draft's live URL — the only entry path the root layout's
		// preview-lifecycle effect tolerates at every intermediate URL.
		await page.goto(`/Builder/${draftId}/preview`);
		await expect(page).toHaveURL(new RegExp(`/${draftId}(/|$)`), {
			timeout: 20_000
		});
		await expect(page.getByText(/Previewing draft/)).toBeVisible();
		await expect(page.getByRole('heading', { name: 'CRM (draft)' })).toBeVisible();

		// Exit returns to the editor — schema edits happen there only.
		await page.getByRole('button', { name: 'Exit preview' }).click();
		await expect(page).toHaveURL(new RegExp(`/Builder/${draftId}/overview$`));
	});

	// ── 3. Author a field in the draft (§4 step 3) ──────────────────
	await phase('author: a field added to the copied Deal through the fields editor', async () => {
		// Preview-exit landed back on the overview tab — reopen the grid.
		await openDoctypesTab(page, 8);
		await page.getByRole('button', { name: /^Deal root/ }).click();
		await expect(page).toHaveURL(new RegExp(`/Builder/${draftId}/Deal/fields$`));

		await page.getByRole('button', { name: 'Add field' }).click();
		// The editor pre-selects the new field with the auto key `new_field`;
		// rename it through the Key input (sanitized to [a-z0-9_]).
		await page.getByLabel('Key', { exact: true }).fill(ADDED_FIELD);
		await page.getByLabel('Title', { exact: true }).fill('Tie Breaker');

		await page.getByRole('button', { name: 'Save', exact: true }).click();
		// Draft-mode `Doctype::Update` accepted the edit: the flash turns to
		// "Saved" (and shows the backend error there when it did not).
		await expect(page.getByRole('button', { name: 'Saved', exact: true })).toBeVisible();
	});

	await phase('author: the live crm.Deal stays unchanged', async () => {
		const body = await getJson(
			request,
			`/Api/core/DocType/${SOURCE}.Deal`,
			'the live Deal definition'
		);
		const fields = body.data.fields as Record<string, Record<string, unknown>>;
		expect(fields[ADDED_FIELD]).toBeUndefined();
		expect(body.data.schema_version).toBe(1);
	});

	// ── 4. Declare the replicate field in the draft (§4 step 4) ─────────
	await phase('replicate: the draft declares the cross-domain replicate field', async () => {
		// The UI owns Key/Type/Title only — the `replicate` config has no
		// widget, so the declaration rides the draft-mode authoring API.
		// Shape per doc/backend/replication.md: `{via, field}` — `via` is the
		// local reference field, `field` is the live source field.
		//
		// The structure copy relinked the copied Deal's `company_id` at the
		// draft's own Company (the relink contract, verified below). The edge
		// must reach the LIVE producer, so the authoring re-points it at
		// `crm.Company` — a draft may reference other domains; a draft source
		// is what the validator refuses. The two authored fields are a
		// structural change, so the write also carries the version the
		// publish gate demands (live + 1) with a no-op migration entry.
		const body = await getJson(
			request,
			`/Api/core/DocType/${encodeURIComponent(`${draftId}.Deal`)}`,
			'the draft Deal definition'
		);
		const draftFields = body.data.fields as Record<string, Record<string, unknown>>;
		// The relink ran at copy time — the copied Deal's company target is
		// the draft's own identity, not the live crm one.
		expect(draftFields.company_id.doctype).toBe(`${draftId}.Company`);
		expect(draftFields[ADDED_FIELD].type).toBe('string');

		const script = String(body.data.script ?? '');
		const versioned = repointReference(
			{
				...body.data,
				schema_version: FIRST_GATE_VERSION,
				migrations: { 1: 'migrate_from_1' },
				script: withMigrationFn(script, 1)
			},
			'company_id',
			`${SOURCE}.Company`
		);
		expect(String(versioned.script)).not.toBe(script);
		(versioned.fields as Record<string, Record<string, unknown>>)[REPLICA_FIELD] = {
			type: 'string',
			title: 'Company Name',
			description: 'Replicated from the referenced crm.Company name.',
			replicate: { via: 'company_id', field: SOURCE_FIELD }
		};
		await putDoctypeDefinition(
			request,
			`${draftId}.Deal`,
			versioned,
			'drafting the replicate field'
		);

		// The bundle's own Customer replicate edge rides the same reference
		// field — re-point it too, so both edges reach the live producer and
		// one ticket covers them.
		const customer = await getJson(
			request,
			`/Api/core/DocType/${encodeURIComponent(`${draftId}.Customer`)}`,
			'the draft Customer definition'
		);
		await putDoctypeDefinition(
			request,
			`${draftId}.Customer`,
			repointReference(customer.data as Record<string, unknown>, 'company_id', `${SOURCE}.Company`),
			're-pointing the draft Customer edge'
		);

		const reread = await getJson(
			request,
			`/Api/core/DocType/${encodeURIComponent(`${draftId}.Deal`)}`,
			'the draft Deal definition after the replicate write'
		);
		const fields = reread.data.fields as Record<string, Record<string, unknown>>;
		expect(fields[REPLICA_FIELD].replicate).toEqual({
			via: 'company_id',
			field: SOURCE_FIELD
		});
		// The deliberate cross-domain edge survived the write.
		expect(fields.company_id.doctype).toBe(`${SOURCE}.Company`);
		expect(reread.data.schema_version).toBe(FIRST_GATE_VERSION);
	});

	// ── 5. Draft isolation (§4 step 5) ──────────────────────────────────
	await phase('isolation: the draft stays cut from the live definitions', async () => {
		// The copied draft definition is a row the admin can read on
		// core.DocType — but the LIVE surface it came from never converged:
		// the registry's EXISTS filter (draft doctypes are neither producers
		// nor consumers) is what keeps the declaration inert, and what the
		// post-publish phase turns on.
		const live = await getJson(
			request,
			`/Api/core/DocType/${SOURCE}.Deal`,
			'the live Deal definition'
		);
		const liveFields = live.data.fields as Record<string, unknown>;
		expect(liveFields[ADDED_FIELD]).toBeUndefined();
		expect(liveFields[REPLICA_FIELD]).toBeUndefined();

		// The authoring-time Validator (`Replication::Validator`, surfaced by
		// the draft's aggregated /check) reviewed the draft declaration: it
		// flags the missing producer-side grant — the runtime fail-closed
		// contract — and does NOT reject the edge with the draft-isolation
		// error (that guard is for live consumers replicating from drafts). A
		// draft source WOULD be inert and issue-free: the re-point in the
		// previous phase is what keeps this edge genuinely cross-domain.
		const check = await getJson(
			request,
			`/Api/core/Domain/${draftId}/check`,
			'the draft domain check'
		);
		const checkData = check.data as {
			issue_count: number;
			doctypes: Array<{
				doctype_id: string;
				issues: Array<{ category: string; message: string }>;
			}>;
		};
		expect(checkData.issue_count).toBeGreaterThan(0);
		const dealCheck = checkData.doctypes.find((dt) => dt.doctype_id === `${draftId}.Deal`);
		expect(dealCheck, 'the check aggregates the draft Deal').toBeTruthy();
		const replicationIssue = dealCheck?.issues.find(
			(issue) => issue.category === 'replication' && issue.message.includes(REPLICA_FIELD)
		);
		expect(replicationIssue, 'the validator surfaces the replicate edge').toBeTruthy();
		// The new-model wording: the consumer's publish files the ticket.
		expect(replicationIssue?.message).toContain('files a ticket');
		expect(replicationIssue?.message).not.toContain('cannot replicate from draft domains');

		// The versioned draft passes the publish-gate read-only diagnostic:
		// the structural change carries live + 1 with its migration entry, and
		// the gate judges the relinked definition — the only remaining diffs
		// are the authored fields and the deliberate cross-domain edge.
		const gateIssues = checkData.doctypes.flatMap((dt) =>
			dt.issues.filter((issue) => issue.category === 'publish_gate')
		);
		expect(gateIssues, 'the versioned draft passes the publish gate').toEqual([]);
	});

	// ── 6. Fresh publish (§4 step 6) ────────────────────────────────────
	await phase('publish: fresh publish lands crmdraft and files the grant ticket', async () => {
		// Back on the editor overview so the bar drives this draft's store.
		await page.goto(`/Builder/${draftId}/overview`);
		await expect(page.getByText('from crm')).toBeVisible();

		const report = await publishViaDialog(page, TARGET);

		// The draft declared cross-domain edges (the authored Deal edge plus
		// the CRM bundle's Customer edge), so the publish filed tickets and
		// the dialog stayed open on the report. The admin publisher holds the
		// acceptance right (D11) — the filed ticket lands Active at once.
		expect(report, 'the publish files a grant ticket for the crm edges').toBeTruthy();
		const ticket = report!.grant_tickets.find((t) => t.producer === SOURCE);
		expect(ticket, 'the ticket names the crm producer').toBeTruthy();
		expect(ticket!.filed, 'a fresh publish files a new grant').toBe(true);
		expect(ticket!.active, 'the admin publisher files active (D11)').toBe(true);
		expect(
			ticket!.edges.some(
				(edge) => edge.doctype === PRODUCER_DOCTYPE && edge.tags.includes(DEFAULT_TAG)
			),
			'the ticket claims the Company doctype under the default tag'
		).toBe(true);

		// The untagged-fields warning renders for an edge naming `default` —
		// every untagged Company field flows once the grant is active.
		await expect(page.getByRole('dialog').getByText('An edge pulls untagged fields')).toBeVisible();

		// The only exit — the draft URL behind the dialog is dead.
		await continueFromReport(page, TARGET);
		await expect(page).toHaveURL(new RegExp(`/${TARGET}(/|$)`));

		// Structure copy: the published Deal carries both authored changes.
		const published = await getJson(
			request,
			`/Api/core/DocType/${TARGET}.Deal`,
			'the published Deal definition'
		);
		const fields = published.data.fields as Record<string, Record<string, unknown>>;
		expect(fields[ADDED_FIELD]).toBeTruthy();
		expect(fields[REPLICA_FIELD].replicate).toEqual({
			via: 'company_id',
			field: SOURCE_FIELD
		});

		// Copy-and-drop: the draft is gone, the target is live. A tombstone
		// read answers 410 (Document::Read's deleted path); 404 would only
		// apply if the row were fully absent.
		const dropStatus = (await request.get(`/Api/core/Domain/${draftId}`)).status();
		expect([404, 410], 'the published draft is dropped').toContain(dropStatus);
		const targetBody = await getJson(
			request,
			`/Api/core/Domain/${TARGET}`,
			'the target domain show'
		);
		expect(targetBody.data.draft).toBeFalsy();
	});

	// ── 7. Post-publish grant + activation state (§4 step 7) ────────────
	await phase('grant: the filed ticket is active and the replica settles', async () => {
		// The publish filed the grant inside the producer's subtree — the one
		// bounded foreign write. Read it back: one grant document, parented
		// under the producer domain, naming the consumer, carrying the
		// Company resource with the `default` tag mask.
		const grants = await listProducerGrants(request, SOURCE, TARGET);
		expect(grants, 'the producer subtree holds exactly one grant for the consumer').toHaveLength(1);
		const grant = grants[0];
		expect(grant.content.active, 'the admin publisher filed it active (D11)').toBe(true);

		// The `active` flag is read-only on the wire: a document PATCH that
		// names it must be rejected with the standard validation-failure shape
		// (422), even from the admin.
		const readOnly = await request.patch(`/Api/core/DomainGrant/${grant.id}`, {
			headers: CSRF_HEADERS,
			data: { active: false }
		});
		expect(readOnly.status(), 'the active flag refuses document writes').toBe(422);
		const readOnlyBody = (await readOnly.json()) as {
			details?: Array<{ field?: string; code?: string }>;
		};
		expect(
			readOnlyBody.details?.some((d) => d.field === 'active' && d.code === 'read_only'),
			'the rejection names the active field as read-only'
		).toBe(true);

		// The registry rebuilds lazily — the grant is in the DB (filed at
		// publish), so the source event finds the gate open. The step authors
		// its own source company (the constants block says why the seeded
		// company is unusable). Reference values are stored qualified — the
		// form the replica edge matches against the source event's id.
		const company = await createDoc(
			request,
			SOURCE,
			'Company',
			{ name: SOURCE_NAME_INITIAL },
			`creating the source company in ${SOURCE}`
		);
		sourceCompanyId = company.id;
		sourceCompanyRef = `${SOURCE}.Company.${sourceCompanyId}`;

		// The published Deal's `stage_id` is domain-local (the relink) and
		// `crmdraft.PipelineStage` ships empty — author the stage first.
		const stage = await createDoc(
			request,
			TARGET,
			'PipelineStage',
			{ name: DEAL_STAGE_NAME, order: 1 },
			`creating the ${TARGET} pipeline stage`
		);
		const stageRef = `${TARGET}.PipelineStage.${stage.id}`;

		// The consumer documents reference the source company explicitly;
		// SyncPull writes their replica values at create time — the gate is
		// already open, no deactivation/re-activation round trip needed.
		const deal = await createDoc(
			request,
			TARGET,
			'Deal',
			{
				title: DEAL_TITLE,
				value: DEAL_VALUE,
				stage_id: stageRef,
				company_id: sourceCompanyRef
			},
			`creating the ${TARGET} deal referencing ${sourceCompanyRef}`
		);
		dealId = deal.id;
		expect(deal.content[REPLICA_FIELD], 'SyncPull pulls the initial replica value').toBe(
			SOURCE_NAME_INITIAL
		);

		const customer = await createDoc(
			request,
			TARGET,
			'Customer',
			{
				status: 'active',
				industry: 'technology',
				company_id: sourceCompanyRef
			},
			`creating the ${TARGET} customer referencing ${sourceCompanyRef}`
		);
		customerId = customer.id;
		// `name` is the CRM bundle's own replicate field — same source field.
		expect(customer.content.name, 'SyncPull pulls the initial replica value').toBe(
			SOURCE_NAME_INITIAL
		);

		// The source mutation fires the real event; the replication handler
		// propagates asynchronously. Poll — never sleep (a timeout is a
		// failure, not a retry).
		await patchJson(
			request,
			`/Api/${SOURCE}/Company/${sourceCompanyId}`,
			{ [SOURCE_FIELD]: SOURCE_NAME_UPDATED },
			'mutating the source company name'
		);

		// The transform rides inside the polled callback — expect.poll
		// asserts on the callback's return value.
		await expect
			.poll(async () => (await readDoc(request, TARGET, 'Deal', dealId))[REPLICA_FIELD], {
				timeout: REPLICATION_SETTLE,
				message: 'the deal replica should settle'
			})
			.toBe(SOURCE_NAME_UPDATED);
		await expect
			.poll(async () => (await readDoc(request, TARGET, 'Customer', customerId)).name, {
				timeout: REPLICATION_SETTLE,
				message: 'the customer replica should settle'
			})
			.toBe(SOURCE_NAME_UPDATED);
	});

	// ── 8. Overwrite publish (§4 step 8) ────────────────────────────────
	await phase('overwrite: drafting crm again after the drop', async () => {
		draftId = await draftFromLiveDomain(page, 'CRM');
		// Same copied structure, but none of the draft edits — that is the
		// removal the overwrite will land on the live domain.
		await page.goto(`/Builder/${draftId}/overview`);
		await openDoctypesTab(page, 8);
	});

	await phase('overwrite: the version gate rejects the un-versioned draft', async () => {
		// The target exists, so the first POST answers 409 and the dialog asks
		// for the explicit overwrite confirmation. Confirming re-sends with
		// `overwrite: true` — the gate then compares definition versions. The
		// fresh draft differs structurally from the live target on TWO
		// axes — the authored fields are absent, and the copy's internal
		// reference targets were relinked to the fresh draft identity (the
		// live target deliberately keeps the cross-domain `crm.Company` edge)
		// — without carrying `schema_version = live + 1`: the gate answers 422
		// and the dialog surfaces it. The response carries the FIRST gate
		// failure in the draft's id order — Customer sorts before Deal.
		await page
			.getByRole('button', { name: /^Publish/ })
			.first()
			.click();
		const dialog = page.getByRole('dialog');
		await expect(dialog.getByText('Publish draft domain')).toBeVisible();
		const nameInput = page.getByLabel('Target domain name');
		await expect(nameInput).not.toHaveValue('', { timeout: 20_000 });
		await nameInput.fill(TARGET);
		await expect(nameInput).toHaveValue(TARGET);
		await dialog.getByRole('button', { name: /^Publish/ }).click();

		// The 409 lands: the confirmation replaces the form.
		await expect(dialog.getByText(/already exists/)).toBeVisible();
		await dialog.getByRole('button', { name: `Publish over ${TARGET}` }).click();

		await expect(dialog.getByRole('alert')).toContainText(
			`Doctype '${TARGET}.Customer' changed structure: schema_version must be ${FIRST_GATE_VERSION} (draft has 1)`
		);
	});

	await phase('overwrite: the versioned draft passes the gate and lands', async () => {
		// Make the draft honest about its structural change: version = live+1
		// with a migration entry whose function exists in the script (a no-op
		// Lua migration is acceptable per doc/backend/draft-domains.md). The
		// reference targets need the same honesty: re-point Deal's and
		// Customer's `company_id` at the live producer, matching the target
		// definitions the first publish landed — then the only structural
		// diff left is the missing authored fields, which the version covers.
		const draftDeal = await getJson(
			request,
			`/Api/core/DocType/${encodeURIComponent(`${draftId}.Deal`)}`,
			'the second draft Deal definition'
		);
		const script = String(draftDeal.data.script ?? '');
		const migratedScript = withMigrationFn(script, FIRST_GATE_VERSION);
		expect(migratedScript).not.toBe(script);

		await putDoctypeDefinition(
			request,
			`${draftId}.Deal`,
			repointReference(
				{
					...draftDeal.data,
					schema_version: GATE_VERSION,
					migrations: { [FIRST_GATE_VERSION]: 'migrate_from_2' },
					script: migratedScript
				},
				'company_id',
				`${SOURCE}.Company`
			),
			'versioning and cross-domaining the draft Deal for the gate'
		);

		const draftCustomer = await getJson(
			request,
			`/Api/core/DocType/${encodeURIComponent(`${draftId}.Customer`)}`,
			'the second draft Customer definition'
		);
		await putDoctypeDefinition(
			request,
			`${draftId}.Customer`,
			repointReference(
				draftCustomer.data as Record<string, unknown>,
				'company_id',
				`${SOURCE}.Company`
			),
			're-pointing the draft Customer edge for the gate'
		);

		// The dialog is still open with the name filled — assert it, then
		// submit again; the 409 returns, the confirmation shows, and the
		// confirmed overwrite publish now passes the gate.
		// The dialog keeps the name across a failed submit (the re-seed is
		// bound to the open transition), but the re-fill before the click is
		// cheap insurance against any flake between error and resubmit.
		const dialog = page.getByRole('dialog');
		const nameInput = page.getByLabel('Target domain name');
		await nameInput.fill(TARGET);
		await expect(nameInput).toHaveValue(TARGET);
		await dialog.getByRole('button', { name: /^Publish/ }).click();
		await expect(dialog.getByText(/already exists/)).toBeVisible();
		await dialog.getByRole('button', { name: `Publish over ${TARGET}` }).click();

		// The overwrite narrows nothing and the bundle is unchanged — the
		// merge touches nothing (no widening), so NO ticket report this time:
		// the dialog closes on plain success and the caller navigates.
		await expect(dialog).not.toBeVisible({ timeout: 60_000 });

		await page.goto(`/${TARGET}`);
		await expect(page).toHaveURL(new RegExp(`/${TARGET}(/|$)`));

		// The published surface matched the draft: the overwritten
		// definition carried the draft's shape verbatim — the two draft-
		// authored fields are gone, the version and migration landed.
		const published = await getJson(
			request,
			`/Api/core/DocType/${TARGET}.Deal`,
			'the overwritten Deal definition'
		);
		expect(published.data.schema_version).toBe(GATE_VERSION);
		const fields = published.data.fields as Record<string, Record<string, unknown>>;
		expect(fields[ADDED_FIELD]).toBeUndefined();
		expect(fields[REPLICA_FIELD]).toBeUndefined();
		expect(published.data.migrations).toEqual({ [String(FIRST_GATE_VERSION)]: 'migrate_from_2' });
		// The deliberate cross-domain edge survives the relink-and-overwrite
		// (the persist relink only rewrites the draft's own identity).
		expect(fields.company_id.doctype).toBe(`${SOURCE}.Company`);

		const dropStatus = (await request.get(`/Api/core/Domain/${draftId}`)).status();
		expect([404, 410], 'the overwritten draft is dropped').toContain(dropStatus);
	});

	// ── 9. Epilogue: the surviving edge still flows ─────────────────────
	await phase('epilogue: the surviving replicate edge keeps flowing', async () => {
		// The overwrite replaced the Deal definition (edge gone with it) but
		// `crmdraft.Customer` kept the CRM-bundle edge on the same source
		// field, and the filed grant survived the overwrite untouched (union
		// unchanged). A fresh source mutation must still land there — live
		// replication survives publish.
		await patchJson(
			request,
			`/Api/${SOURCE}/Company/${sourceCompanyId}`,
			{ [SOURCE_FIELD]: SOURCE_NAME_FINAL },
			'mutating the source company name again'
		);

		await expect
			.poll(async () => (await readDoc(request, TARGET, 'Customer', customerId)).name, {
				timeout: REPLICATION_SETTLE,
				message: 'the surviving replica should settle'
			})
			.toBe(SOURCE_NAME_FINAL);
	});
});
