<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import LoginAttemptsWarning from './LoginAttemptsWarning.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/LoginAttemptsWarning',
		component: LoginAttemptsWarning
	});
</script>

<Story name="Default" args={{ attempts: 9 }} />

<!-- B-139 — the warning renders the count from the backend's 401
	`meta.remaining_attempts`, mirroring the MFA challenge path's inline
	"N attempts remaining" copy. -->
<Story
	name="RendersRemainingAttempts"
	args={{ attempts: 7 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const alert = canvas.getByRole('alert');
		await expect(alert).toHaveTextContent('7 attempts remaining');
	}}
/>

<Story
	name="SingularRemainingAttempt"
	args={{ attempts: 1 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const alert = canvas.getByRole('alert');
		await expect(alert).toHaveTextContent('1 attempt remaining');
	}}
/>
