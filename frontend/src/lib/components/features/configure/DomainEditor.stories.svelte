<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import DomainEditor from './DomainEditor.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { MockDataDriver } from '$lib/datasource/MockDriver';
	import { setPermissions } from '$lib/permissions.svelte';

	// The admin wildcard hydrates the permission store so the grants tab
	// renders its editing affordances (create / save / activate / delete
	// are `can()`-gated, and read-only rendering is the safe default).
	// The no-manifest case is covered by the held-access card's lack of
	// controls in components without the store set (e.g. app stories).
	setPermissions({ '*.*': ['*'] });

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DomainEditor',
		component: DomainEditor,
		tags: ['autodocs'],
		argTypes: {
			domain: {
				control: 'select',
				options: ['production', 'crm', 'hr', 'core', 'iam', 'identity']
			}
		},
		args: {
			registry: createMockDriver(),
			domain: 'production'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	// `createMockDriver()` seeds `core.Domain` documents only for `core` and
	// `iam` (from data/seeds/core.Domain/documents.yml). Fixture domain docs
	// (hr, crm, production) are dropped because the `core.Domain` DataSource is
	// already cached by the time fixtures apply.
	//
	// These helpers write domain + grant documents directly into the driver's
	// shared docs map so the DomainEditor can load them.

	interface DomainContent {
		name?: string;
		color?: string;
		description?: string;
		draft?: boolean;
		source_domain?: string;
		context_sets?: Record<string, { from: string; select: string; where: Record<string, string> }>;
	}

	interface GrantContent {
		consumer_domain: string;
		resources: { doctype: string; tags: string[] }[];
		active: boolean;
	}

	/** Seed (or overwrite) a `core.Domain` document on a mock driver. */
	function seedDomain(driver: MockDataDriver, id: string, content: DomainContent): void {
		const now = new Date().toISOString();
		driver.docs.set(id, {
			id,
			domain: 'core',
			doc_type: 'Domain',
			content: { ...content },
			version: 1,
			schema_version: 1,
			created_at: now,
			updated_at: now,
			mutations: [],
			deleted_at: null
		});
	}

	/** Seed one `core.DomainGrant` document. `parentId` is the producer
	 *  domain (the grant lives in the producer's tree); the issued-grants
	 *  child list resolves children by the `production.grants.` id prefix
	 *  on the mock, so issued grant ids carry that prefix while held ones
	 *  are free-form. */
	function seedGrant(
		driver: MockDataDriver,
		id: string,
		parentId: string,
		content: GrantContent
	): void {
		const now = new Date().toISOString();
		driver.docs.set(id, {
			id,
			domain: 'core',
			doc_type: 'DomainGrant',
			content: { ...content },
			version: 1,
			schema_version: 1,
			display_name: `for ${content.consumer_domain.replace('core.Domain.', '')}`,
			parent_id: parentId,
			created_at: now,
			updated_at: now,
			mutations: [],
			deleted_at: null
		});
	}

	/** A driver with the `production` domain document populated — it has a
	 *  context set (`my_teams`), an active grant to `hr` (Project +
	 *  TeamMember at tag grain), and an inactive ticket to `catalog`. */
	function productionDriver(): MockDataDriver {
		const driver = createMockDriver();
		seedDomain(driver, 'production', {
			name: 'Production',
			color: '#10B981',
			description:
				'Production planning — teams, projects, and tasks.\n\nUsed to exercise RBAC team-scoped access via the `my_teams` context set.',
			context_sets: {
				my_teams: { from: 'TeamMember', where: { account: '$self' }, select: '$parent_id' }
			}
		});
		seedGrant(driver, 'production.grants.g1', 'production', {
			consumer_domain: 'core.Domain.hr',
			resources: [
				{ doctype: 'Project', tags: ['default', 'schedule'] },
				{ doctype: 'TeamMember', tags: ['default'] }
			],
			active: true
		});
		seedGrant(driver, 'production.grants.g2', 'production', {
			consumer_domain: 'core.Domain.catalog',
			resources: [{ doctype: 'Team', tags: ['default'] }],
			active: false
		});
		return driver;
	}

	/** A driver with the `production` domain document plus a held grant —
	 *  `identity` files one in production's favour (the consumer side). */
	function heldAccessDriver(): MockDataDriver {
		const driver = productionDriver();
		seedGrant(driver, 'identity.grants.h9', 'identity', {
			consumer_domain: 'core.Domain.production',
			resources: [{ doctype: 'Person', tags: ['default', 'contact'] }],
			active: true
		});
		seedGrant(driver, 'identity.grants.h10', 'identity', {
			consumer_domain: 'core.Domain.production',
			resources: [{ doctype: 'Identifier', tags: ['pii'] }],
			active: false
		});
		return driver;
	}

	/** A driver with the `production` domain document plus two
	 *  `core.DomainEditor` grant rows, for the Editors-tab story. */
	function editorsDriver(): MockDataDriver {
		const driver = productionDriver();
		seedEditorRow(driver, 'de_pm_alex', 'account_pm_alex', 'production');
		seedEditorRow(driver, 'de_dao', 'account_eng_dao', 'production');
		return driver;
	}

	/** Seed one `core.DomainEditor` grant row into a mock driver. */
	function seedEditorRow(
		driver: MockDataDriver,
		id: string,
		accountId: string,
		domainId: string
	): void {
		const now = new Date().toISOString();
		driver.docs.set(id, {
			id,
			domain: 'core',
			doc_type: 'DomainEditor',
			content: { account: `iam.Account.${accountId}`, domain: domainId },
			version: 1,
			schema_version: 1,
			created_at: now,
			updated_at: now,
			mutations: [],
			deleted_at: null
		});
	}

	/** A driver with seeded `crm`, `hr`, and `identity` domain documents. */
	function multiDomainDriver(): MockDataDriver {
		const driver = createMockDriver();
		seedDomain(driver, 'crm', {
			name: 'CRM',
			color: '#2196F3',
			description: 'Customer relationship management — companies, contacts, deals, and activities.'
		});
		seedDomain(driver, 'hr', {
			name: 'Human Resources',
			color: '#7C4DFF',
			description: 'Human resources — candidates, employees, and career events.'
		});
		seedDomain(driver, 'identity', {
			name: 'Identity',
			color: '#FF7043',
			description: 'Person identity records shared across domains.'
		});
		return driver;
	}
</script>

<Story
	name="IssuedGrants"
	args={{ domain: 'production', registry: productionDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Both issued grants render with their consumer labels and states.
		await waitFor(() => expect(canvas.getByText('for hr')).toBeInTheDocument());
		await expect(canvas.getByText('for catalog')).toBeInTheDocument();
		await expect(canvas.getByText('Active')).toBeInTheDocument();
		await expect(canvas.getByText('Awaiting acceptance')).toBeInTheDocument();
		// The active grant lists its resources: doctype selects carry the
		// entry names; the tag inputs show the granted tags. Both grants'
		// TeamMember/Team rows share the `default` tag string — count them.
		await expect(canvas.getAllByDisplayValue('default, schedule')).toHaveLength(1);
		await expect(canvas.getAllByDisplayValue('default')).toHaveLength(2);
		// The context set alias from the same tab still renders.
		await expect(canvas.getByText('$my_teams')).toBeInTheDocument();
	}}
/>

<Story
	name="HeldAccess"
	args={{ domain: 'production', registry: heldAccessDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The held section lists the two tickets identity filed in production's
		// favour — producer label plus per-entry doctype + tags, read-only.
		await waitFor(() => expect(canvas.getAllByText('from identity')).toHaveLength(2));
		await expect(canvas.getAllByText('Person').length).toBeGreaterThan(0);
		await expect(canvas.getByText('contact')).toBeInTheDocument();
		await expect(canvas.getByText('pii')).toBeInTheDocument();
		// The acceptance controls belong to the issued side only: the active
		// issued grant offers Deactivate, the inactive one Activate — the
		// held cards carry neither (the producer owns the document).
		await expect(canvas.getByRole('button', { name: 'Deactivate' })).toBeInTheDocument();
		await expect(canvas.getByRole('button', { name: 'Activate' })).toBeInTheDocument();
	}}
/>

<Story
	name="IssuedAndHeldCounts"
	args={{ domain: 'production', registry: heldAccessDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The header tab badge counts both grant lists plus the context
		// sets (the tab's other section): 2 issued + 2 held + 1 set = 5.
		await waitFor(() => expect(canvas.getAllByText('from identity')).toHaveLength(2));
		await expect(canvas.getByRole('button', { name: /Grants/ })).toHaveTextContent(/5/);
	}}
/>

<Story
	name="ProductionDoctypes"
	args={{ domain: 'production', registry: productionDriver(), tab: 'doctypes' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The doctype list renders the domain's doctypes. 'Project' appears both
		// in the sidebar list and in the schematic, so use getAllByText.
		await expect(canvas.getAllByText('Project').length).toBeGreaterThan(0);
		await expect(canvas.getAllByText('Team').length).toBeGreaterThan(0);
	}}
/>

<Story
	name="ProductionEditors"
	args={{ domain: 'production', registry: editorsDriver(), tab: 'editors' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The header tab carries the grant count.
		await expect(canvas.getByRole('button', { name: /Editors/ })).toHaveTextContent(/2/);
		// The grant rows resolve to the fixture accounts' display names. The
		// manage affordances stay hidden — the story runs without a permission
		// manifest (read-only rendering is the safe default).
		await waitFor(() => {
			expect(canvas.getByText('Alex Okafor')).toBeVisible();
			expect(canvas.getByText('Dao Chen')).toBeVisible();
		});
	}}
/>

<Story
	name="CRM"
	args={{ domain: 'crm', registry: multiDomainDriver(), tab: 'doctypes' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// CRM has doctypes with reference edges (Company → Contact, Deal → Company).
		await expect(canvas.getAllByText('Company').length).toBeGreaterThan(0);
	}}
/>

<Story
	name="HR"
	args={{ domain: 'hr', registry: multiDomainDriver(), tab: 'doctypes' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// 'Candidate' appears both in the list and the schematic.
		await expect(canvas.getAllByText('Candidate').length).toBeGreaterThan(0);
	}}
/>

<Story
	name="Core"
	args={{ domain: 'core', registry: createMockDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Core holds no grants (the mock driver seeds none), and the seeded
		// editor context sets still render. The grants load is async even for
		// a system domain, so wait for the empty state.
		await waitFor(() => expect(canvas.getByText(/No issued grants/)).toBeInTheDocument());
		await expect(canvas.getByText('$editor_domains')).toBeInTheDocument();
		await expect(canvas.getByText('$editor_doctypes')).toBeInTheDocument();
		await expect(canvas.getByText('$editor_draft_domains')).toBeInTheDocument();
	}}
/>

<Story
	name="Iam"
	args={{ domain: 'iam', registry: createMockDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The iam domain document is bare — both empty-state cards render.
		// The grants load is async even for a system domain, so wait for the
		// first empty state before asserting the second.
		await waitFor(() => expect(canvas.getByText(/No issued grants/)).toBeInTheDocument());
		await expect(canvas.getByText(/No context sets/)).toBeInTheDocument();
	}}
/>

<Story
	name="DeleteDomainDangerZone"
	args={{ domain: 'production', registry: productionDriver(), tab: 'overview' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The danger zone renders with the type-to-confirm gate: the button
		// stays disabled until the input carries the exact domain id. The
		// button is never clicked here — the drop call hits the real session
		// layer, which stories do not stub.
		const input = canvas.getByPlaceholderText('Type production to confirm');
		const button = canvas.getByRole('button', { name: 'Delete domain' });
		await expect(button).toBeDisabled();
		await userEvent.type(input, 'product');
		await expect(button).toBeDisabled();
		await userEvent.type(input, 'ion');
		await expect(button).toBeEnabled();
	}}
/>

<Story
	name="SystemDomainHasNoDangerZone"
	args={{ domain: 'core', registry: createMockDriver(), tab: 'overview' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// System domains cannot be dropped (the backend refuses), so no
		// danger zone renders — a dead button would only confuse.
		await expect(canvas.queryByRole('button', { name: 'Delete domain' })).not.toBeInTheDocument();
		// The identity section still renders so the story proves the tab works.
		await expect(canvas.getByLabelText('Label')).toBeInTheDocument();
	}}
/>

<Story
	name="HeaderWiring"
	args={{
		domain: 'production',
		registry: productionDriver(),
		tab: 'overview',
		ontabselect: fn(),
		crumb: { label: 'Domains', href: '/Configure/domains' }
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The crumb link carries the caller's label and resolved href —
		// mounts outside the Builder point the crumb at their own list.
		await expect(canvas.getByRole('link', { name: 'Domains' })).toHaveAttribute(
			'href',
			'/Configure/domains'
		);
		// A tab click calls the mount's callback with the picked tab; the
		// editor itself performs no navigation on that surface. The tab strip
		// renders after the async core.Domain load, so wait for it first.
		await waitFor(() =>
			expect(canvas.getByRole('button', { name: /Doctypes/ })).toBeInTheDocument()
		);
		await userEvent.click(canvas.getByRole('button', { name: /Doctypes/ }));
		await expect(args.ontabselect).toHaveBeenCalledWith('doctypes');
	}}
/>

<!-- Interaction stories: the editor clones the loaded core.Domain doc on
	mount, so checkbox/click writes land in the editor's working copy and
	never mutate args in place (shared-page Vitest render race, audit 44). -->

<Story
	name="ResourceRowAddRemove"
	args={{ domain: 'production', registry: productionDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Each issued card carries one add-row button; the first grant
		// starts with two resource rows, the second with one.
		const addButtons = () => canvas.getAllByRole('button', { name: 'Add doctype' });
		await waitFor(() => expect(addButtons()).toHaveLength(2));
		// Adding a row to the first grant appends an empty entry — its
		// remove button carries the row placeholder label.
		await userEvent.click(addButtons()[0]);
		// Adding a row appends an empty entry — its remove button carries the
		// row placeholder label.
		const newRemove = () => canvas.getByRole('button', { name: /Remove new entry entry/ });
		await waitFor(() => expect(newRemove()).toBeInTheDocument());
		// Removing the appended row restores the first grant's shape.
		await userEvent.click(newRemove());
		await waitFor(() =>
			expect(canvas.queryByRole('button', { name: /Remove new entry entry/ })).toBeNull()
		);
	}}
/>

<Story
	name="ContextSetWhereRowAddRemove"
	args={{ domain: 'production', registry: productionDriver(), tab: 'grants' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The seeded my_teams context set has one where row (account = $self).
		const keyInputs = () => canvas.getAllByRole('textbox', { name: 'Where key for my_teams' });
		await expect(keyInputs()).toHaveLength(1);
		// Adding a row appends a fresh entry (field_N = $self defaults).
		await userEvent.click(canvas.getByRole('button', { name: '+ Add' }));
		await expect(keyInputs()).toHaveLength(2);
		// Removing the first row leaves the appended one in place.
		const removeButtons = canvas.getAllByRole('button', { name: 'Remove where entry' });
		await userEvent.click(removeButtons[0]);
		await expect(keyInputs()).toHaveLength(1);
	}}
/>
