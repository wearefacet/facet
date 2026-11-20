<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import AccountCredentialActions from './AccountCredentialActions.svelte';
	import CanFixture from './CanFixture.svelte';
	import ConfirmDialog from '../../primitives/surfaces/ConfirmDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/AccountCredentialActions',
		component: AccountCredentialActions,
		tags: ['autodocs']
	});

	/** Manifest granting the credential actions on `iam.Account`. */
	const credManifest = { 'iam.Account': ['provision_credentials', 'mfa_disable'] };

	/** Credential-state reader stub — one entry per id from a shared base. */
	function stubStates(base: Record<string, unknown>) {
		return async (ids: string[]) =>
			new Map(
				ids.map((id) => [
					id,
					{
						id,
						has_password: false,
						must_change_pw: false,
						mfa_enabled: false,
						invite_pending: false,
						federated: false,
						...base
					}
				])
			);
	}

	/** Wait for the mounted state fetch to settle. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, userEvent, within } from 'storybook/test';
</script>

<!--
	The panel mounts on the `iam.Account` show page. The state read is async,
	so every play settles it before asserting. The permission gates come from
	the injected manifest (CanFixture); the state-dependent labels come from
	the injected `fetchStates` stub.
-->

<Story
	name="Bootstrap account — invite and password, no MFA"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Send invite' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Generate password' })).toBeVisible();
		await expect(canvas.queryByRole('button', { name: 'Reset MFA' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.ada"
				email="ada@company.com"
				fetchStates={stubStates({})}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Invite pending and password set flip the labels"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Resend invite' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Regenerate password' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.ada"
				email="ada@company.com"
				fetchStates={stubStates({ invite_pending: true, has_password: true })}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Suspended account hides the password action"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Send invite' })).toBeVisible();
		await expect(canvas.queryByRole('button', { name: 'Generate password' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.susp"
				email="susp@company.com"
				status="suspended"
				fetchStates={stubStates({})}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Reset MFA hidden for a purely federated account"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		// No local password → the IdP is the factor of record;
		// the rule also holds when an IdP-linked account reports MFA.
		await expect(canvas.queryByRole('button', { name: 'Reset MFA' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.sso"
				email="sso@company.com"
				fetchStates={stubStates({ federated: true, mfa_enabled: true })}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Federated account with a local password keeps Reset MFA"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Reset MFA' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.sso2"
				email="sso2@company.com"
				fetchStates={stubStates({ federated: true, has_password: true, mfa_enabled: true })}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Reset MFA confirm gate — cancel fires nothing"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Reset MFA' }));

		// The confirm dialog is up.
		const body = within(document.body);
		await expect(body.getByText('Reset MFA?')).toBeVisible();

		// Cancel — the panel stays, no error banner appears (no POST fired).
		const dialog = within(body.getByRole('dialog'));
		await userEvent.click(dialog.getByRole('button', { name: 'Cancel' }));
		await sleep(50);
		await expect(canvas.getByRole('button', { name: 'Reset MFA' })).toBeVisible();
		await expect(canvas.queryByText(/failed/i)).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<div style="position: relative; min-height: 120px;">
				<AccountCredentialActions
					docId="iam.Account.kim"
					email="kim@company.com"
					fetchStates={stubStates({ mfa_enabled: true })}
				/>
				<!-- The single global host that backs `confirm()`. -->
				<ConfirmDialog />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="No permissions — panel renders nothing"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
>
	{#snippet template()}
		<!-- No manifest: fail-closed. -->
		<CanFixture manifest={null}>
			<AccountCredentialActions
				docId="iam.Account.noperm"
				email="noperm@company.com"
				fetchStates={stubStates({})}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Service account — no credential actions"
	play={async ({ canvasElement }) => {
		await sleep(100);
		const canvas = within(canvasElement);
		// A service account holds no credential actions even with the
		// provisioning grant.
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={credManifest}>
			<AccountCredentialActions
				docId="iam.Account.bot"
				email="bot@company.com"
				serviceAccount
				fetchStates={stubStates({})}
			/>
		</CanFixture>
	{/snippet}
</Story>
