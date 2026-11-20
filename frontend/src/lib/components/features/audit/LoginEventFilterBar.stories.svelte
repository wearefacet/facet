<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, within } from 'storybook/test';
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Audit/LoginEventFilterBar',
		component: FilterBar
	});

	// The `iam.LoginEvent` filter surface (B-137): the seeded `event` enum
	// field carries `filters: [equality, text_search]`, so its derived
	// `operators` metadata offers `eq` / `in` / `match` — the add-filter
	// menu lists Event Type and the chip renders the event-name dropdown.
	// The synthesized timestamps ride on `showSystemTimestamps` (default on).
	// The enum values mirror the live seed — re-sync from
	// `data/seeds/iam.LoginEvent/definition.yml` when the vocabulary moves.
	const loginEventDef: DoctypeDef = {
		domain: 'iam',
		doctype: 'LoginEvent',
		description: 'Append-only audit log for authentication events.',
		fields: [
			{
				key: 'account_id',
				type: 'string',
				title: 'Account ID',
				operators: ['eq']
			},
			{
				key: 'event',
				type: 'enum',
				title: 'Event Type',
				operators: ['eq', 'in', 'match', 'starts_with'],
				values: [
					'login',
					'logout',
					'refresh',
					'refresh_reuse',
					'refresh_failed',
					'app_refresh',
					'mcp_refresh',
					'lockout',
					'password_reset_requested',
					'password_reset_used',
					'password_change',
					'password_login_denied',
					'invite_sent',
					'invite_accepted',
					'temp_password_generated',
					'mfa_enrolled',
					'mfa_enabled',
					'mfa_disabled',
					'consent_granted',
					'layer1_denied',
					'api_key_created',
					'api_key_revoked',
					'session_revoked',
					'app_sessions_revoked',
					'oidc_login',
					'oidc_provisioned',
					'oidc_denied'
				].map((k) => ({ key: k, label: k }))
			},
			{
				key: 'app',
				type: 'string',
				title: 'App',
				operators: ['eq']
			}
		],
		children: [],
		actions: []
	};
</script>

<Story name="Default" args={{ filters: {}, onFilterChange: fn() }}>
	{#snippet template(args)}
		<div style="padding: 12px; background: var(--surface);">
			<FilterBar
				doctype={loginEventDef}
				filters={args.filters}
				onFilterChange={args.onFilterChange}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-137 — an active event filter renders the enum dropdown chip with the
	picked event name. -->
<Story
	name="EventFilterChip"
	args={{ filters: { event__eq: 'session_revoked' }, onFilterChange: fn() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Event Type')).toBeTruthy();
		// The picked value displays inside the enum combobox input — an input
		// value, not text content. The chip carries two comboboxes in DOM
		// order: the operator picker, then the value picker.
		const combos = canvas.getAllByRole('combobox');
		await expect(combos).toHaveLength(2);
		await expect(combos[1]).toHaveValue('session_revoked');
	}}
>
	{#snippet template(args)}
		<div style="padding: 12px; background: var(--surface);">
			<FilterBar
				doctype={loginEventDef}
				filters={args.filters}
				onFilterChange={args.onFilterChange}
			/>
		</div>
	{/snippet}
</Story>
