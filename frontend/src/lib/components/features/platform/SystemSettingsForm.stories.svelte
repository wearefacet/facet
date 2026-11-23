<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import SystemSettingsForm from './SystemSettingsForm.svelte';

	/**
	 * Component tests for the grouped runtime-settings form. The play
	 * functions exercise the sparse-patch contract, the override badge +
	 * reset-to-file control, and the save-time secret staging (one Save:
	 * stage every typed plaintext, then patch with the handles) with a
	 * synthetic stager — no backend. `baseData()` mirrors the real GET
	 * shape (secret paths absent from `values`), so the tests exercise the
	 * wire shape the backend actually sends.
	 *
	 * The data bag is rebuilt per story (a module-level constant would leak
	 * edits across stories — the component mutates its `fields` state).
	 */

	/**
	 * The real GET shape: the non-secret effective values keyed by dot-path.
	 * The backend excludes the secret paths (`assistant.api_key`,
	 * `mail.smtp.password`) from `values` — their state rides `pinned` only.
	 * Seeding them here would test fiction: the component must render its
	 * secret rows from the path list alone. The artifact and retention
	 * numbers show the file defaults; `artifact.storage.type` is the
	 * read-only deployment value. The policy and localization enums and the
	 * assistant name always carry an effective value (the file tier), so
	 * the fixture shows them resolved.
	 */
	function baseData() {
		return {
			values: {
				'assistant.name': 'Assistant',
				'assistant.api_endpoint': 'https://api.openai.com/v1',
				'assistant.model': 'gpt-4o',
				'assistant.system_prompt': null,
				'assistant.max_tokens': null,
				'assistant.temperature': null,
				'assistant.max_history': null,
				'assistant.auto_execute_tools': true,
				'mail.adapter': 'dev',
				'mail.from_address': 'no-reply@example.test',
				'mail.from_name': 'Facet',
				'mail.smtp.host': 'localhost',
				'mail.smtp.port': 587,
				'mail.smtp.username': null,
				'mail.smtp.use_tls': true,
				'artifact.storage.type': 'filesystem',
				'artifact.grant_ttl_seconds': 3600,
				'artifact.grant_ttl_media_seconds': 21600,
				'artifact.grant_prune_days': 7,
				'artifact.prune_after_days': 30,
				'mutations.retention_days': 180,
				'tombstone.content_retention_days': 30
			},
			pinned: ['assistant.model', 'mail.smtp.host']
		};
	}

	/**
	 * `baseData()` with the adapter switched to `smtp` — the SMTP transport
	 * rows render only when the adapter is smtp, so stories that touch them
	 * start from this bag.
	 */
	function smtpData() {
		const data = baseData();
		return {
			values: { ...data.values, 'mail.adapter': 'smtp' },
			pinned: data.pinned
		};
	}

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };

	const saveMock = (args: { onSave: unknown }): AnyMock => args.onSave as unknown as AnyMock;
	const stageMock = (args: { onStageSecret: unknown }): AnyMock =>
		args.onStageSecret as unknown as AnyMock;
	const testMailMock = (args: { onTestMail?: unknown }): AnyMock =>
		args.onTestMail as unknown as AnyMock;
	const testAssistantMock = (args: { onTestAssistant?: unknown }): AnyMock =>
		args.onTestAssistant as unknown as AnyMock;
	const { Story } = defineMeta({
		title: 'Components/Features/Platform/SystemSettingsForm',
		component: SystemSettingsForm,
		tags: ['autodocs']
	});
</script>

<Story
	name="RendersGroupsAndBadges"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The chapter rail lists all four chapters; each group renders with
		// its fields. The nav links and the group headings share their
		// labels, so the assertions scope by role.
		const nav = canvas.getByRole('navigation', { name: 'Settings chapters' });
		for (const label of [
			'Assistant',
			'Mail',
			'Localization',
			'Security',
			'Artifacts',
			'Retention'
		]) {
			await expect(within(nav).getByRole('button', { name: label })).toBeVisible();
			await expect(canvas.getByRole('heading', { name: label })).toBeVisible();
		}
		await expect(canvas.getByLabelText('Model')).toBeVisible();
		await expect(canvas.getByLabelText('API endpoint')).toBeVisible();
		// Pinned fields carry the override badge; unpinned ones do not.
		const modelRow = canvas.getByText('Model').closest('.field-row');
		await expect(modelRow).not.toBeNull();
		await expect(within(modelRow as HTMLElement).getByText('override')).toBeVisible();
		const endpointRow = canvas.getByText('API endpoint').closest('.field-row');
		await expect(within(endpointRow as HTMLElement).queryByText('override')).toBeNull();
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="ChapterNavTracksSelection"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const nav = canvas.getByRole('navigation', { name: 'Settings chapters' });
		// The first chapter starts active; clicking another moves the
		// selection (the spy holds during the programmatic scroll).
		await expect(within(nav).getByRole('button', { name: 'Assistant' })).toHaveAttribute(
			'aria-current',
			'true'
		);
		await userEvent.click(within(nav).getByRole('button', { name: 'Retention' }));
		await expect(within(nav).getByRole('button', { name: 'Retention' })).toHaveAttribute(
			'aria-current',
			'true'
		);
		await expect(within(nav).getByRole('button', { name: 'Assistant' })).not.toHaveAttribute(
			'aria-current'
		);
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="SparseSaveOnlyDirtyFields"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Edit exactly one field.
		const model = canvas.getByLabelText('Model');
		await userEvent.clear(model);
		await userEvent.type(model, 'gpt-4o-mini');
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));

		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		// The patch carries only the edited field, nested like the config file.
		await expect(patch).toEqual({ assistant: { model: 'gpt-4o-mini' } });
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="ResetToFileSendsExplicitNull"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The pinned model row carries the reset-to-file control.
		const modelRow = canvas.getByText('Model').closest('.field-row') as HTMLElement;
		await userEvent.click(within(modelRow).getByRole('button', { name: 'Reset to file' }));

		// The badge flips to the pending-reset state; the input disables.
		await expect(within(modelRow).getByText('reset pending')).toBeVisible();

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ assistant: { model: null } });
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="SaveStagesThenPatches"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The API key field shows "not set" (not pinned) and never a value.
		const key = canvas.getByLabelText('API key');
		await expect(key).toHaveValue('');

		// Type the plaintext plus one non-secret edit — Save is one click.
		const model = canvas.getByLabelText('Model');
		await userEvent.clear(model);
		await userEvent.type(model, 'gpt-4o-mini');
		await userEvent.type(key, 'sk-super-secret');
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));

		// The save staged the plaintext, then patched with the handle —
		// the plaintext reaches neither the patch nor the DOM, and the
		// non-secret edit rides the same PATCH.
		await waitFor(() => expect(stageMock(args).mock.calls.length).toBe(1));
		await expect(stageMock(args).mock.calls[0]).toEqual(['assistant.api_key', 'sk-super-secret']);
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			assistant: { api_key: 'sh_stage-handle-1', model: 'gpt-4o-mini' }
		});
		await expect(key).toHaveValue('sh_stage-handle-1');
		await expect(canvas.queryByText('sk-super-secret')).toBeNull();
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_stage-handle-1')
	}}
/>

<Story
	name="TwoSecretsOneSave"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Change both secret fields, then one Save.
		await userEvent.type(canvas.getByLabelText('API key'), 'sk-both');
		await userEvent.type(canvas.getByLabelText('SMTP password'), 'smtp-both');
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));

		// Both fields staged (in path order), one PATCH carries both handles.
		await waitFor(() => expect(stageMock(args).mock.calls.length).toBe(2));
		await expect(stageMock(args).mock.calls[0]).toEqual(['assistant.api_key', 'sk-both']);
		await expect(stageMock(args).mock.calls[1]).toEqual(['mail.smtp.password', 'smtp-both']);
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			assistant: { api_key: 'sh_handle-assistant' },
			mail: { smtp: { password: 'sh_handle-mail' } }
		});
	}}
	args={{
		data: smtpData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (path: string, _value: string) => `sh_handle-${path.split('.')[0]}`)
	}}
/>

<Story
	name="SecretSetShowsStateFromPinned"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// mail.smtp.host is pinned; mail.smtp.password is not — its input
		// placeholder says "not set", the pinned host's row carries the badge.
		const hostRow = canvas.getByText('SMTP host').closest('.field-row') as HTMLElement;
		await expect(within(hostRow).getByText('override')).toBeVisible();
	}}
	args={{
		data: {
			...smtpData(),
			pinned: ['mail.smtp.host', 'mail.smtp.password', 'assistant.api_key']
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="BoolAndNumberCoercions"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Flip auto-execute tools off and set max tokens.
		await userEvent.click(canvas.getByLabelText('Auto-execute tools'));
		const maxTokens = canvas.getByLabelText('Max tokens');
		await userEvent.type(maxTokens, '512');

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			assistant: { auto_execute_tools: false, max_tokens: 512 }
		});
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="AdapterEnumSelect"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The adapter combobox opens on click and lists the two adapters.
		const adapter = canvas.getByLabelText('Adapter');
		await userEvent.click(adapter);
		await userEvent.click(within(document.body).getByText('smtp (real delivery)'));

		// Selecting smtp reveals the transport rows — the SMTP section
		// follows the live select value, not the saved snapshot.
		await waitFor(() => expect(canvas.getByLabelText('SMTP host')).toBeVisible());

		// Selecting smtp alone does not save — host is already pinned, so the
		// write gate would pass; the save carries only the adapter change.
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ mail: { adapter: 'smtp' } });
	}}
	args={{
		data: {
			values: { ...baseData().values, 'mail.smtp.host': 'smtp.example.test' },
			pinned: ['mail.smtp.host']
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="StageFailureAbortsSave"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A non-secret edit rides the same save — a failed stage aborts
		// the whole save, not just the secret field.
		const model = canvas.getByLabelText('Model');
		await userEvent.clear(model);
		await userEvent.type(model, 'gpt-4o-mini');
		const key = canvas.getByLabelText('API key');
		await userEvent.type(key, 'sk-retry-me');
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));

		// The failing stager's message renders on the row; the typed
		// plaintext stays in the input so the admin can retry.
		const keyRow = key.closest('.field-row') as HTMLElement;
		await waitFor(() => expect(within(keyRow).getByText('stage rejected')).toBeVisible());
		await expect(key).toHaveValue('sk-retry-me');

		// No PATCH ran (the non-secret edit is unsaved too); Save
		// re-enables for the retry.
		await expect(saveMock(args).mock.calls.length).toBe(0);
		const save = canvas.getByRole('button', { name: 'Save' }) as HTMLButtonElement;
		await waitFor(() => expect(save.disabled).toBe(false));
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => {
			throw new Error('stage rejected');
		})
	}}
/>

<Story
	name="NoStageButton"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The stage button is gone — Save does the staging.
		await expect(canvas.queryByRole('button', { name: 'Stage value' })).toBeNull();
		// The set / not-set placeholders still render from `pinned`.
		await expect(canvas.getByPlaceholderText('set — type a new value to rotate')).toBeVisible();
		await expect(canvas.getByPlaceholderText('not set — follows the file')).toBeVisible();
	}}
	args={{
		data: {
			...smtpData(),
			pinned: ['assistant.model', 'mail.smtp.host', 'assistant.api_key']
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="KeepForeverTogglePinsZero"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const row = canvas.getByText('History retention').closest('.field-row') as HTMLElement;
		// Toggle keep-forever on: the number input disables at 0 and the
		// save pins 0. (The switch is the row's only toggle — the Toggle
		// label pairs with a Bits UI button, so the query goes by role.)
		const forever = within(row).getByRole('switch');
		await userEvent.click(forever);
		const input = within(row).getByLabelText('History retention') as HTMLInputElement;
		await expect(input).toBeDisabled();
		await expect(input).toHaveValue(0);

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ mutations: { retention_days: 0 } });
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="KeepForeverToggleOffRestores"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const row = canvas.getByText('History retention').closest('.field-row') as HTMLElement;
		const forever = within(row).getByRole('switch');
		// On then off without a save: the effective value (180) returns and
		// the row is clean again — nothing to save.
		await userEvent.click(forever);
		await userEvent.click(forever);
		const input = within(row).getByLabelText('History retention') as HTMLInputElement;
		await expect(input).toBeEnabled();
		await expect(input).toHaveValue(180);
		const save = canvas.getByRole('button', { name: 'Save' }) as HTMLButtonElement;
		await expect(save).toBeDisabled();
		await expect(saveMock(args).mock.calls.length).toBe(0);
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="KeepForeverOffOnPinnedZeroSendsNull"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The document pins 0: the toggle starts checked (disabled input).
		const row = canvas.getByText('History retention').closest('.field-row') as HTMLElement;
		const forever = within(row).getByRole('switch');
		const input = within(row).getByLabelText('History retention') as HTMLInputElement;
		await expect(input).toBeDisabled();

		// Toggle off: the pin leaves through the explicit-null reset flow —
		// the row shows "reset pending" with the undo affordance.
		await userEvent.click(forever);
		await expect(within(row).getByText('reset pending')).toBeVisible();

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ mutations: { retention_days: null } });
	}}
	args={{
		data: {
			values: { ...baseData().values, 'mutations.retention_days': 0 },
			pinned: ['mutations.retention_days']
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="ChaptersNavAndHelpersRender"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The resolution-order legend is gone — the per-field helpers carry
		// the meaning now.
		await expect(canvas.queryByText(/Values resolve in order/)).toBeNull();

		// Every field carries a helper that states what it does — the
		// custom-instructions helper answers the empty-value question
		// directly.
		const promptRow = canvas.getByText('Custom instructions').closest('.field-row') as HTMLElement;
		await expect(within(promptRow).getByText(/no custom instructions/)).toBeVisible();

		// The SMTP sub-section separates the transport fields from the
		// top-level mail fields — rendered here because the adapter is smtp.
		const hostRow = canvas.getByText('SMTP host').closest('.field-row') as HTMLElement;
		await expect(hostRow).not.toBeNull();
		await expect(within(hostRow.parentElement as HTMLElement).getByText('SMTP')).toBeVisible();

		// The storage adapter renders read-only with the effective value —
		// no input, no patch path.
		await expect(canvas.getByText('filesystem (local disk)')).toBeVisible();
		await expect(canvas.getByText(/Fixed at deployment/)).toBeVisible();
		const adapterRow = canvas.getByText('Storage adapter').closest('.field-row') as HTMLElement;
		await expect(adapterRow.getAttribute('data-readonly')).toBe('true');
		await expect(within(adapterRow).queryByRole('textbox')).toBeNull();
	}}
	args={{
		data: smtpData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="SmtpHiddenUnderNone"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The dev adapter reads as "none (no email)" — Facet will not send.
		// With none active, the SMTP sub-heading and every transport row
		// stay out of the DOM.
		await expect(canvas.queryByText('SMTP')).toBeNull();
		await expect(canvas.queryByLabelText('SMTP host')).toBeNull();
		await expect(canvas.queryByLabelText('SMTP password')).toBeNull();
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="ArtifactAndRetentionNumbersSave"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Edit one knob in each of the new chapters.
		await userEvent.clear(canvas.getByLabelText('Grant TTL'));
		await userEvent.type(canvas.getByLabelText('Grant TTL'), '7200');
		await userEvent.clear(canvas.getByLabelText('History retention'));
		await userEvent.type(canvas.getByLabelText('History retention'), '90');
		await userEvent.clear(canvas.getByLabelText('Deleted content retention'));
		await userEvent.type(canvas.getByLabelText('Deleted content retention'), '14');

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			artifact: { grant_ttl_seconds: 7200 },
			mutations: { retention_days: 90 },
			tombstone: { content_retention_days: 14 }
		});
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="SecurityEnumPathsSave"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The security chapter renders the factor-type and auth-mode selects;
		// the enforcement select is visible while the pending type is totp.
		const enforcement = canvas.getByLabelText('MFA enforcement');
		await expect(enforcement).toBeVisible();

		// Flip the mode to SSO only — the select is a combobox like the
		// adapter's; pick the option from the floating list.
		const mode = canvas.getByLabelText('Authentication mode');
		await userEvent.click(mode);
		await userEvent.click(within(document.body).getByText('SSO only'));

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ iam: { auth: { mode: 'oidc_only' } } });
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="EnforcementHiddenUnderNone"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The pending factor type drives visibility: switching to None
		// removes the enforcement select from the DOM (a control that does
		// nothing is a control that lies).
		const type = canvas.getByLabelText('MFA factor type');
		await userEvent.click(type);
		await userEvent.click(within(document.body).getByText('None'));

		await expect(canvas.queryByLabelText('MFA enforcement')).toBeNull();

		// And the save carries the type switch.
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ iam: { mfa: { type: 'none' } } });
	}}
	args={{
		data: {
			values: { ...baseData().values, 'iam.mfa.type': 'totp', 'iam.mfa.enforcement': 'always' },
			pinned: []
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="CredentialLinkTtlRendersWithReset"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The Security chapter renders the credential-link TTL with its
		// effective value; the pinned row carries the override badge and the
		// reset-to-file control.
		const ttl = canvas.getByLabelText('Credential link TTL') as HTMLInputElement;
		await expect(ttl).toHaveValue(86400);

		const row = canvas.getByText('Credential link TTL').closest('.field-row') as HTMLElement;
		await expect(within(row).getByText('override')).toBeVisible();
		await expect(within(row).getByRole('button', { name: 'Reset to file' })).toBeVisible();

		// Reset to file: the row moves to the pending-reset state and the
		// save carries the explicit null.
		await userEvent.click(within(row).getByRole('button', { name: 'Reset to file' }));
		await expect(within(row).getByText('reset pending')).toBeVisible();

		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(saveMock(args).mock.calls.length).toBe(1));
		const patch = saveMock(args).mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ iam: { change_password_expiration: null } });
	}}
	args={{
		data: {
			values: { ...baseData().values, 'iam.change_password_expiration': 86400 },
			pinned: ['iam.change_password_expiration']
		},
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused')
	}}
/>

<Story
	name="TestMailSendsSavedConnector"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The recipient starts at the signed-in account's address.
		const recipient = canvas.getByLabelText('Recipient') as HTMLInputElement;
		await expect(recipient).toHaveValue('admin@example.test');

		await userEvent.click(canvas.getByRole('button', { name: 'Send test email' }));

		await waitFor(() => expect(testMailMock(args).mock.calls.length).toBe(1));
		await expect(testMailMock(args).mock.calls[0][0]).toBe('admin@example.test');

		// The success line names the transport that carried the probe.
		await waitFor(() =>
			expect(canvas.getByText('Delivered via smtp to admin@example.test.')).toBeVisible()
		);
	}}
	args={{
		data: smtpData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused'),
		onTestMail: fn(async (_to: string) => ({
			adapter: 'smtp',
			from_address: 'no-reply@example.test',
			to: 'admin@example.test'
		})),
		defaultTestRecipient: 'admin@example.test'
	}}
/>

<Story
	name="TestMailShowsTransportFailure"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Send test email' }));

		// The backend's 502 message is the diagnostic — it renders verbatim.
		await waitFor(() =>
			expect(
				canvas.getByText('Delivery failed: Mail delivery failed: 535 authentication failed')
			).toBeVisible()
		);
	}}
	args={{
		data: smtpData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused'),
		onTestMail: fn(async (_to: string) => {
			throw new Error('Mail delivery failed: 535 authentication failed');
		}),
		defaultTestRecipient: 'admin@example.test'
	}}
/>

<Story
	name="TestMailWarnsAboutUnsavedEdits"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Editing a mail field makes a test run the OLD connector — the form
		// says so instead of letting the operator test a stale setup.
		const host = canvas.getByLabelText('SMTP host');
		await userEvent.clear(host);
		await userEvent.type(host, 'smtp.changed.test');

		await waitFor(() =>
			expect(
				canvas.getByText('Save your changes first — the test uses the saved connector.')
			).toBeVisible()
		);
	}}
	args={{
		data: smtpData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused'),
		onTestMail: fn(async (_to: string) => ({
			adapter: 'smtp',
			from_address: 'no-reply@example.test',
			to: 'admin@example.test'
		})),
		defaultTestRecipient: 'admin@example.test'
	}}
/>

<Story
	name="TestAssistantReportsReply"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Send test request' }));

		await waitFor(() => expect(testAssistantMock(args).mock.calls.length).toBe(1));

		// The success line names the model that answered and its reply.
		await waitFor(() => expect(canvas.getByText('gpt-4o replied: pong')).toBeVisible());
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused'),
		onTestAssistant: fn(async () => ({
			model: 'gpt-4o',
			endpoint: 'https://provider.example/v1',
			reply: 'pong'
		}))
	}}
/>

<Story
	name="TestAssistantShowsFailure"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Send test request' }));

		// The backend's message is the diagnostic — it renders verbatim.
		await waitFor(() =>
			expect(
				canvas.getByText('The test failed: Assistant request failed: HTTP 401 — invalid_api_key')
			).toBeVisible()
		);
	}}
	args={{
		data: baseData(),
		saving: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onStageSecret: fn(async (_path: string, _value: string) => 'sh_unused'),
		onTestAssistant: fn(async () => {
			throw new Error('Assistant request failed: HTTP 401 — invalid_api_key');
		})
	}}
/>
