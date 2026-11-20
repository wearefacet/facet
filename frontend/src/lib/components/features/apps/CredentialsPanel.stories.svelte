<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import CredentialsPanel from './CredentialsPanel.svelte';
	import type { AppContent } from '$lib/app/appTypes';
	import type { DeploymentRow } from '$lib/app/deployments';
	import type { DocumentMeta } from '$lib/datasource/types';
	import { setPermissions } from '$lib/permissions.svelte';

	/**
	 * Component tests for the Overview tab body. The panel renders from
	 * props only; every action is a spy, so no backend runs. The admin
	 * wildcard hydrates the global permission store before the first story
	 * mounts, so the Can-gated affordances (deploy, lifecycle, delete)
	 * render. Fixtures rebuild per story — a shared constant would leak
	 * edits across stories.
	 */

	setPermissions({ '*.*': ['*'] });

	function appMeta(id: string): DocumentMeta {
		return {
			id,
			mid: `mid-${id}`,
			domain: 'app',
			doc_type: 'Deployment',
			version: 1,
			schema_version: 1,
			created_at: '2026-10-01T09:00:00Z',
			updated_at: '2026-10-01T09:00:00Z'
		};
	}

	/** A public (PKCE) web app — the origins block applies. */
	function publicApp(): AppContent {
		return {
			slug: 'time-off',
			name: 'Time Off',
			description: 'Leave requests and approvals.',
			client_id: '01J8Z0M8Z3Q7V4XK9P2RNW5T6H',
			client_type: 'public',
			status: 'active',
			owner_id: '01J8Z0M8Z3OWNER',
			allowed_origins: ['https://time.example.com'],
			redirect_uris: ['https://time.example.com/oauth/callback']
		};
	}

	/** A backend app — the service identity block applies. */
	function confidentialApp(): AppContent {
		return {
			...publicApp(),
			client_type: 'confidential',
			service_role_id: 'iam.Roles.app-time-off',
			service_account_id: '01J8Z0M8Z3SVCACC'
		};
	}

	/** A managed app — Facet serves it, so the deployment panel applies. */
	function managedApp(): AppContent {
		return {
			...publicApp(),
			host: 'time.company.tld',
			active_deployment: 'app.Deployment.dep-2'
		};
	}

	/** A draft app — the lifecycle offers Activate, not Disable. */
	function draftApp(): AppContent {
		return { ...publicApp(), status: 'draft' };
	}

	/** One deployment history row; `fileCount` drives the files label. */
	function row(id: string, revision: number, note: string, fileCount: number): DeploymentRow {
		return {
			meta: appMeta(id),
			data: {
				app_id: 'app.App.app-1',
				revision,
				note,
				spa: true,
				files: Array.from({ length: fileCount }, (_, i) => ({ path: `f${i}.js` }))
			}
		};
	}

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const cbMock = (args: Record<string, unknown>, key: string): AnyMock =>
		args[key] as unknown as AnyMock;

	const baseArgs = () => ({
		onActivateDeployment: fn(async (_row: DeploymentRow) => {}),
		onSetStatus: fn(async (_status: 'active' | 'disabled') => {}),
		onDelete: fn(() => {}),
		onDeploy: fn(() => {})
	});

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/CredentialsPanel',
		component: CredentialsPanel,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Identity rows render from the document content.
		await expect(canvas.getByText('Time Off')).toBeVisible();
		await expect(canvas.getByText('time-off')).toBeVisible();
		await expect(canvas.getByText('01J8Z0M8Z3Q7V4XK9P2RNW5T6H')).toBeVisible();
		// A public app shows origins and redirects, not the service identity.
		await expect(canvas.getByText('Origins and redirects')).toBeVisible();
		await expect(canvas.getByText('https://time.example.com')).toBeVisible();
		await expect(canvas.queryByText('Service identity')).toBeNull();
		// Unmanaged: no deployment panel.
		await expect(canvas.queryByText('Deployment')).toBeNull();
		// Lifecycle: an active app offers Disable.
		await expect(canvas.getByText('active')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Disable' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Delete app' })).toBeVisible();
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="ConfidentialServiceIdentity"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A confidential app shows both blocks: the origins and redirects
		// (it signs in through a browser) plus the service identity.
		await expect(canvas.getByText('Service identity')).toBeVisible();
		await expect(canvas.getByText('iam.Roles.app-time-off')).toBeVisible();
		await expect(canvas.getByText('01J8Z0M8Z3SVCACC')).toBeVisible();
		await expect(canvas.getByText('Origins and redirects')).toBeVisible();
	}}
	args={{ app: confidentialApp(), ...baseArgs() }}
/>

<Story
	name="ManagedDeploymentPanel"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Deployment')).toBeVisible();
		// The active build shows revision, note, file count, SPA flag.
		await expect(canvas.getByText('r2')).toBeVisible();
		await expect(canvas.getByText('fix login bug')).toBeVisible();
		await expect(canvas.getByText('2 files')).toBeVisible();
		await expect(canvas.getByText('SPA')).toBeVisible();
		// History lists only the non-active row, with its rollback action.
		await expect(canvas.getByText('History')).toBeVisible();
		await expect(canvas.getByText('r1')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Activate' })).toBeVisible();
		// The deploy affordance opens the deploy flow.
		await expect(canvas.getByRole('button', { name: 'Deploy a build' })).toBeVisible();
	}}
	args={{
		app: managedApp(),
		deployments: [row('dep-2', 2, 'fix login bug', 2), row('dep-1', 1, 'first upload', 1)],
		...baseArgs()
	}}
/>

<Story
	name="ActivateHistoryRow"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Roll back: the Activate button on the history row targets that row.
		await userEvent.click(canvas.getByRole('button', { name: 'Activate' }));
		await waitFor(() => expect(cbMock(args, 'onActivateDeployment').mock.calls.length).toBe(1));
		const called = cbMock(args, 'onActivateDeployment').mock.calls[0][0] as DeploymentRow;
		await expect(called.meta.id).toBe('dep-1');
	}}
	args={{
		app: managedApp(),
		deployments: [row('dep-2', 2, 'fix login bug', 2), row('dep-1', 1, 'first upload', 1)],
		...baseArgs()
	}}
/>

<Story
	name="ActivateInFlightDisables"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The row that activates right now cannot be activated again.
		await expect(canvas.getByRole('button', { name: 'Activate' })).toBeDisabled();
	}}
	args={{
		app: managedApp(),
		deployments: [row('dep-2', 2, 'fix login bug', 2), row('dep-1', 1, 'first upload', 1)],
		activatingId: 'dep-1',
		...baseArgs()
	}}
/>

<Story
	name="LifecycleTransition"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A draft offers Activate; clicking reports the 'active' transition.
		await userEvent.click(canvas.getByRole('button', { name: 'Activate' }));
		await waitFor(() => {
			const calls = cbMock(args, 'onSetStatus').mock.calls;
			expect(calls.length).toBe(1);
			expect(calls[0][0]).toBe('active');
		});
	}}
	args={{ app: draftApp(), ...baseArgs() }}
/>

<Story
	name="DeleteApp"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The host confirms before it deletes; the panel only reports.
		await userEvent.click(canvas.getByRole('button', { name: 'Delete app' }));
		await waitFor(() => expect(cbMock(args, 'onDelete').mock.calls.length).toBe(1));
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="DeployOpensFlow"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The deploy affordance is navigation only; the host resolves the route.
		await userEvent.click(canvas.getByRole('button', { name: 'Deploy a build' }));
		await waitFor(() => expect(cbMock(args, 'onDeploy').mock.calls.length).toBe(1));
	}}
	args={{
		app: managedApp(),
		deployments: [row('dep-2', 2, 'fix login bug', 2)],
		...baseArgs()
	}}
/>
