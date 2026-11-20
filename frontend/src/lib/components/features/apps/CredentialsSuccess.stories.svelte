<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import CredentialsSuccess from './CredentialsSuccess.svelte';
	import type { AppContent } from '$lib/app/appTypes';

	/**
	 * Component tests for the wizard's credentials success screen. The play
	 * functions use synthetic callbacks — no backend: `onGoToApp` records
	 * the hand-off, and the API-key issuance panel renders without a key
	 * status round-trip being asserted (the hook's fetch layer is covered
	 * through the settings-tab stories).
	 */

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const gotoMock = (args: { onGoToApp: unknown }): AnyMock => args.onGoToApp as unknown as AnyMock;

	/** A published public (PKCE) web app. */
	function publicApp(overrides: Partial<AppContent> = {}): AppContent {
		return {
			slug: 'acme-portal',
			name: 'Acme Portal',
			client_id: '01J8Z0M8Z3Q7V4XK9P2RNW5T6H',
			client_type: 'public',
			status: 'active',
			allowed_origins: ['https://acme.example.com'],
			redirect_uris: ['https://acme.example.com/oauth/callback'],
			...overrides
		};
	}

	/** A published backend app — the API-key issuance panel applies. */
	function confidentialApp(overrides: Partial<AppContent> = {}): AppContent {
		return publicApp({ client_type: 'confidential', ...overrides });
	}

	const baseArgs = () => ({
		issuerBase: 'https://facet.company.com',
		onGoToApp: fn(() => {})
	});

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/CredentialsSuccess',
		component: CredentialsSuccess,
		tags: ['autodocs']
	});
</script>

<Story
	name="PublicAppShowsSnippetAndDiscovery"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The success header and the read-only identity fields render.
		await expect(canvas.getByText('Acme Portal is live')).toBeVisible();
		await expect(canvas.getByText('01J8Z0M8Z3Q7V4XK9P2RNW5T6H')).toBeVisible();
		// The sign-in row shows the real authorize deep link (B-200): the
		// shared endpoint discovery advertises, addressed by client id. No
		// per-app /auth/<slug> route exists.
		await expect(
			canvas.getByText(
				'https://facet.company.com/OAuth/authorize?client_id=01J8Z0M8Z3Q7V4XK9P2RNW5T6H'
			)
		).toBeVisible();
		// The public branch: PKCE notice, the TypeScript client snippet,
		// and the discovery link — no API-key panel.
		await expect(canvas.getByText('No client secret')).toBeVisible();
		await expect(canvas.getByText('Start the flow')).toBeVisible();
		await expect(canvas.getByRole('link', { name: 'Discovery document' })).toBeVisible();
		await expect(canvas.queryByText('Generate API key')).toBeNull();
		// The snippet's authorizationEndpoint matches discovery: the same
		// ${issuer}/OAuth/authorize path with the app's client id.
		const snippet = canvas.getByText(/const facet = createClient/);
		expect(snippet.textContent).toContain(
			'authorizationEndpoint: "https://facet.company.com/OAuth/authorize?client_id=01J8Z0M8Z3Q7V4XK9P2RNW5T6H"'
		);
	}}
	args={{ app: publicApp(), appId: 'app.01TEST', ...baseArgs() }}
/>

<Story
	name="GoToAppReportsToHost"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Go to app page' }));
		await expect(gotoMock(args).mock.calls.length).toBe(1);
	}}
	args={{ app: publicApp(), appId: 'app.01TEST', ...baseArgs() }}
/>

<Story
	name="ConfidentialShowsKeyIssuePanel"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The backend branch: the one-time API-key issue panel renders and
		// the public snippet path stays hidden.
		await expect(canvas.getByText('Generate API key')).toBeVisible();
		await expect(canvas.getByText('Acme Portal is live')).toBeVisible();
		await expect(canvas.queryByText('Start the flow')).toBeNull();
	}}
	args={{ app: confidentialApp(), appId: 'app.01TEST', ...baseArgs() }}
/>
