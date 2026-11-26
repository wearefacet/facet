<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import AppGrantsEditor from './AppGrantsEditor.svelte';
	import type { DoctypeCatalogueEntry, AppGrant } from '$lib/app/appTypes';
	import { levelToActions } from '$lib/app/appGrantsMapping';

	// A mock catalogue that exercises every shape the editor renders:
	// - two domains (sales, shared) so the rail has more than one segment;
	// - a root with a child (Company → CompanyMembership) so inheritance and
	//   the clamp are exercised;
	// - a sensitive doctype (Contact) so the lock icon renders;
	// - a named action on Contact so the "Extra abilities" pills render.
	const catalogue: DoctypeCatalogueEntry[] = [
		{
			target: 'crm.Company',
			label: 'Company',
			description: 'A B2B organisation that is a customer, prospect, or partner.',
			domain: 'sales',
			pluralLabel: 'companies'
		},
		{
			target: 'crm.CompanyMembership',
			label: 'CompanyMembership',
			description: 'Links a Contact to a Company.',
			domain: 'sales',
			pluralLabel: 'company memberships',
			parentTarget: 'crm.Company'
		},
		{
			target: 'crm.Contact',
			label: 'Contacts',
			description: 'Names, emails, phone numbers, addresses',
			domain: 'sales',
			pluralLabel: 'contacts',
			sensitive: true,
			namedActions: [{ name: 'export', label: 'Export contacts to a file' }]
		},
		{
			target: 'core.Comment',
			label: 'Comments',
			description: 'Notes people leave on any record',
			domain: 'shared',
			pluralLabel: 'comments'
		}
	];

	// A parent with one child that declares a named action — the
	// ChildNamedActions story pins the child-row pills.
	const childNamedCatalogue: DoctypeCatalogueEntry[] = [
		{
			target: 'crm.Company',
			label: 'Company',
			description: 'Companies',
			domain: 'sales',
			pluralLabel: 'companies'
		},
		{
			target: 'crm.CompanyMembership',
			label: 'CompanyMembership',
			description: 'Links a Contact to a Company.',
			domain: 'sales',
			pluralLabel: 'company memberships',
			parentTarget: 'crm.Company',
			namedActions: [{ name: 'approve', label: 'Approve a membership' }]
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/AppGrantsEditor',
		component: AppGrantsEditor,
		tags: ['autodocs'],
		args: {
			onchange: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<!-- The editor has no intrinsic height (border + padding only) — the
     template wrapper with `min-height` prevents Storybook's fullscreen
     flex from collapsing it. -->
<Story
	name="WizardEmpty"
	args={{
		grants: [],
		doctypeCatalogue: catalogue,
		mode: 'wizard'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('What can this app do?')).toBeVisible();
		await expect(canvas.getByPlaceholderText('Filter doctypes')).toBeVisible();
		// No grant selected → the summary is hidden.
		await expect(canvas.queryByText('What people will see')).toBeNull();
		// Both domains appear in the rail. The active domain defaults to the
		// first with grants, or the first overall — here "sales".
		await expect(canvas.getByRole('tab', { name: /sales/ })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		await expect(canvas.getByRole('tab', { name: /shared/ })).toHaveAttribute(
			'aria-selected',
			'false'
		);
		// The active domain's root doctypes are visible.
		await expect(canvas.getByText('Company')).toBeVisible();
		await expect(canvas.getByText('Contacts')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="SegmentedControlSetsLevel"
	args={{
		grants: [],
		doctypeCatalogue: catalogue,
		mode: 'wizard'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Click the "Read" segment on the Company card. The card becomes
		// active and `onchange` fires with a materialised grants array
		// (Company is a root, so materialisation writes its explicit grant).
		// Anchor the regex to avoid matching "Access level for CompanyMembership".
		const companyGroup = canvas.getByRole('group', {
			name: /^Access level for Company$/
		});
		await userEvent.click(within(companyGroup).getByRole('button', { name: 'Read' }));
		await expect(args.onchange).toHaveBeenCalled();
		const onchange = args.onchange as unknown as { mock: { calls: unknown[][] } };
		const emitted: AppGrant[] = (onchange.mock.calls.at(-1)?.[0] as AppGrant[] | undefined) ?? [];
		await expect(emitted.find((g) => g.target === 'crm.Company')).toBeDefined();
		// Company is a root with children; the child inherits and is
		// materialised to the same level.
		await expect(emitted.find((g) => g.target === 'crm.CompanyMembership')).toBeDefined();
		// The summary appears because at least one grant is now set. Scope the
		// text queries to the summary panel so they don't collide with the
		// segmented-control buttons that share the same labels.
		const summary = canvas
			.getByText('What people will see')
			.closest('.grants-summary') as HTMLElement | null;
		if (!summary) throw new Error('summary panel not rendered');
		const summaryCanvas = within(summary);
		await expect(summaryCanvas.getByText('Read')).toBeVisible();
		await expect(summaryCanvas.getByText(/companies/)).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="ChildInheritsParentLevel"
	args={{
		grants: [{ target: 'crm.Company', actions: levelToActions('write') }],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The parent has write; the child has no explicit grant, so the
		// status tag reads "Write, inherited".
		await expect(canvas.getByText('Write, inherited')).toBeVisible();
		// The parent's grant count appears on the rail segment.
		await expect(canvas.getByRole('tab', { name: /sales/ })).toHaveTextContent('2');
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="ChildSegmentsClampedToParent"
	args={{
		grants: [{ target: 'crm.Company', actions: levelToActions('read') }],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The parent is at read; the child's "Write" and "Full" segments
		// are disabled (greyed) because they exceed the parent's ceiling.
		const childGroup = canvas.getByRole('group', {
			name: /^Access level for CompanyMembership$/
		});
		const childScoped = within(childGroup);
		await expect(childScoped.getByRole('button', { name: 'Write' })).toBeDisabled();
		await expect(childScoped.getByRole('button', { name: 'Full' })).toBeDisabled();
		await expect(childScoped.getByRole('button', { name: 'Read' })).not.toBeDisabled();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="BulkSetDomain"
	args={{
		grants: [],
		doctypeCatalogue: catalogue,
		mode: 'wizard'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// "Set all in sales: Read" bulk-sets every root doctype in the active
		// domain (sales) to read. The bulk-set row sits above the cards; its
		// "Read" button is the only one outside a segmented control. Scope by
		// finding the bulk-set container first.
		const bulk = canvas.getByText(/Set all in sales/).closest('.grants-bulk') as HTMLElement | null;
		if (!bulk) throw new Error('bulk-set row not rendered');
		await userEvent.click(within(bulk).getByRole('button', { name: 'Read' }));
		await expect(args.onchange).toHaveBeenCalled();
		const onchange = args.onchange as unknown as { mock: { calls: unknown[][] } };
		const emitted: AppGrant[] = (onchange.mock.calls.at(-1)?.[0] as AppGrant[] | undefined) ?? [];
		await expect(emitted.find((g) => g.target === 'crm.Company')).toBeDefined();
		await expect(emitted.find((g) => g.target === 'crm.Contact')).toBeDefined();
		await expect(emitted.find((g) => g.target === 'crm.CompanyMembership')).toBeDefined();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="NamedActionPillOnActiveLevel"
	args={{
		grants: [
			{
				target: 'crm.Contact',
				actions: [
					{ name: 'read', required: true },
					{ name: 'write', required: false }
				]
			}
		],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The Contacts card is active (level !== none) so its named-action
		// pills render. The export pill toggle is visible.
		await expect(canvas.getByText('Extra abilities')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Export contacts to a file' })).toBeVisible();
		// The summary renders the grouped consent copy. Scope to the summary
		// panel so the verb text doesn't collide with the segmented-control
		// buttons that share the same labels.
		const summary = canvas
			.getByText('What people will see')
			.closest('.grants-summary') as HTMLElement | null;
		if (!summary) throw new Error('summary panel not rendered');
		const summaryCanvas = within(summary);
		await expect(summaryCanvas.getByText('Read')).toBeVisible();
		// Contact has both read and write, so the "contacts" noun appears in
		// both the Read and Create-and-edit groups. Assert it appears at least
		// once rather than matching exactly one.
		await expect(summaryCanvas.getAllByText(/contacts/).length).toBeGreaterThan(0);
		await expect(summaryCanvas.getByText('Create and edit')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="CoreActionRequiredToggle"
	args={{
		grants: [{ target: 'crm.Contact', actions: levelToActions('write') }],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The Contacts card is at "Write" (read + write, both optional). The
		// required-flag row renders under the segmented control. Scope to the
		// row: the consent summary below repeats the state words.
		const row = canvas
			.getByText('Role must have at setup')
			.closest('.grants-required-row') as HTMLElement | null;
		if (!row) throw new Error('required-flag row not rendered');
		const rowCanvas = within(row);
		await expect(rowCanvas.getByRole('switch', { name: 'Read' })).toBeVisible();
		await expect(rowCanvas.getByRole('switch', { name: 'Create and edit' })).toBeVisible();
		await expect(rowCanvas.getAllByText('optional')).toHaveLength(2);
		// Flip "Read" to required — the CRM scenario: read required, write
		// optional, one grant entry.
		await userEvent.click(rowCanvas.getByRole('switch', { name: 'Read' }));
		await expect(rowCanvas.getByText('required')).toBeVisible();
		await expect(rowCanvas.getAllByText('optional')).toHaveLength(1);
		const onchange = args.onchange as unknown as { mock: { calls: unknown[][] } };
		const emitted: AppGrant[] = (onchange.mock.calls.at(-1)?.[0] as AppGrant[] | undefined) ?? [];
		const contact = emitted.find((g) => g.target === 'crm.Contact');
		// The write flag rides on the canonical create/update pair — the alias
		// is never persisted.
		await expect(contact?.actions).toEqual([
			{ name: 'read', required: true },
			{ name: 'create', required: false },
			{ name: 'update', required: false }
		]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="CanonicalExternalGrants"
	args={{
		// Grants authored outside the editor (API, MCP, an external builder)
		// arrive in the backend's canonical vocabulary: create/update as
		// separate declarations, no `write` alias. The picker must read them
		// at their true level — this is the regression shape of the CRM app
		// whose grants rendered as all-None.
		grants: [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'read', required: true },
					{ name: 'create', required: true },
					{ name: 'update', required: true },
					{ name: 'delete', required: true }
				]
			},
			{
				target: 'crm.CompanyMembership',
				actions: [
					{ name: 'read', required: true },
					{ name: 'create', required: true },
					{ name: 'update', required: true },
					{ name: 'delete', required: true }
				]
			}
		],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The parent card shows Full selected.
		const companyGroup = canvas.getByRole('group', {
			name: /^Access level for Company$/
		});
		await expect(within(companyGroup).getByRole('button', { name: 'Full' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);
		// The child has its own explicit entry, so the tag reads
		// "Full, overridden" — and its segments are enabled (the parent
		// ceiling is full, not none).
		await expect(canvas.getByText('Full, overridden')).toBeVisible();
		const childGroup = canvas.getByRole('group', {
			name: /^Access level for CompanyMembership$/
		});
		await expect(within(childGroup).getByRole('button', { name: 'Read' })).not.toBeDisabled();
		// The consent summary folds create/update into "Create and edit" with
		// the noun list — no bare "create"/"update" lines.
		const summary = canvas
			.getByText('What people will see')
			.closest('.grants-summary') as HTMLElement | null;
		if (!summary) throw new Error('summary panel not rendered');
		const summaryCanvas = within(summary);
		await expect(summaryCanvas.getByText('Read')).toBeVisible();
		await expect(summaryCanvas.getByText('Create and edit')).toBeVisible();
		await expect(summaryCanvas.getByText('Delete')).toBeVisible();
		await expect(summaryCanvas.queryByText('create')).toBeNull();
		await expect(summaryCanvas.queryByText('update')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story
	name="RailSwitchesActiveDomain"
	args={{
		grants: [],
		doctypeCatalogue: catalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// "sales" is active by default; its doctypes are visible.
		await expect(canvas.getByText('Company')).toBeVisible();
		// Switch to "shared".
		await userEvent.click(canvas.getByRole('tab', { name: /shared/ }));
		await expect(canvas.getByRole('tab', { name: /shared/ })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		await expect(canvas.getByText('Comments')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>

<Story name="EditMode">
	{#snippet template()}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor
				grants={[
					{
						target: 'crm.Company',
						actions: levelToActions('write')
					}
				]}
				doctypeCatalogue={catalogue}
				mode="edit"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ChildNamedActions"
	args={{
		// A child doctype declaring a named action — the Task/submit shape: the
		// custom action lives on the child, and the pills must render on the
		// child row or the action stays ungrantable (runtime 403).
		grants: [{ target: 'crm.Company', actions: levelToActions('write') }],
		doctypeCatalogue: childNamedCatalogue,
		mode: 'edit'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The child row renders the Extra abilities pills. The parent has no
		// named actions, so the label appears exactly once.
		await expect(canvas.getAllByText('Extra abilities')).toHaveLength(1);
		// Activating the pill creates the child's explicit entry. The implicit
		// base is the inherited level (write) with the inherited flags — not a
		// bare read — so the displayed level survives the override.
		await userEvent.click(canvas.getByRole('button', { name: 'Approve a membership' }));
		const onchange = args.onchange as unknown as { mock: { calls: unknown[][] } };
		const emitted: AppGrant[] = (onchange.mock.calls.at(-1)?.[0] as AppGrant[] | undefined) ?? [];
		const membership = emitted.find((g) => g.target === 'crm.CompanyMembership');
		await expect(membership?.actions).toEqual([
			{ name: 'read', required: false },
			{ name: 'create', required: false },
			{ name: 'update', required: false },
			{ name: 'approve', required: false }
		]);
		// The status tag flips from inherited to overridden — same level.
		await expect(canvas.getByText('Write, overridden')).toBeVisible();
		// The active pill carries its own required toggle; flipping it marks
		// the named action required. The consent summary repeats the label, so
		// locate the pill through its toggle button, not the text.
		const pill = canvas
			.getByRole('button', { name: 'Approve a membership' })
			.closest('.grants-named-pill') as HTMLElement;
		await userEvent.click(within(pill).getByRole('switch'));
		const last = (onchange.mock.calls.at(-1)?.[0] as AppGrant[] | undefined) ?? [];
		const approve = last
			.find((g) => g.target === 'crm.CompanyMembership')
			?.actions.find((a) => a.name === 'approve');
		await expect(approve?.required).toBe(true);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 600px; padding: 24px; background: var(--surface-2);">
			<AppGrantsEditor {...args} />
		</div>
	{/snippet}
</Story>
