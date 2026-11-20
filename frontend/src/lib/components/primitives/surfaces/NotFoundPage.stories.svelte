<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import NotFoundPage from './NotFoundPage.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/NotFoundPage',
		component: NotFoundPage,
		tags: ['autodocs'],
		argTypes: {
			status: { control: 'select', options: ['404', '410', '500'] },
			deleted: { control: 'boolean' },
			historyHref: { control: 'text' }
		}
	});
</script>

<script lang="ts">
	import AppShell from './AppShell.svelte';
	import type { Crumb } from './Topbar.svelte';

	const crumbs: Crumb[] = [{ label: 'Facet', href: '/' }];
</script>

<Story
	name="NotFound"
	args={{ status: '404', message: 'Doctype _06fwqaxxkw1q.TestIntDefault not found' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('404')).toBeVisible();
		await expect(canvas.getByText('The page could not be found')).toBeVisible();
		await expect(canvas.getByText('Doctype _06fwqaxxkw1q.TestIntDefault not found')).toBeVisible();
	}}
/>

<Story
	name="Deleted"
	args={{
		status: '410',
		deleted: true,
		message: 'hr.Employee.06FWRBQTR87M2CBBMQN61CEBZ2',
		historyHref: '/hr/Employee/06FWRBQTR87M2CBBMQN61CEBZ2/history'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('410')).toBeVisible();
		await expect(canvas.getByText('The document has been deleted')).toBeVisible();
		const history = canvas.getByRole('button', { name: 'History' });
		await expect(history).toBeVisible();
		await expect(history).toHaveAttribute(
			'href',
			'/hr/Employee/06FWRBQTR87M2CBBMQN61CEBZ2/history'
		);
	}}
/>

<Story
	name="DeletedWithoutHistory"
	args={{ status: '410', deleted: true, message: 'hr.Employee.06FWRBQTR87M2CBBMQN61CEBZ2' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('410')).toBeVisible();
		// Without a history href only the dashboard action renders.
		await expect(canvas.queryByRole('button', { name: 'History' })).toBeNull();
	}}
/>

<Story
	name="ServerError"
	args={{ status: '500', message: 'Internal server error — please retry' }}
/>

<Story
	name="InLayout"
	args={{ status: '404', message: 'Doctype _06fwqaxxkw1q.TestIntDefault not found' }}
>
	{#snippet template(args)}
		<AppShell {crumbs} collapsed={false}>
			<NotFoundPage status={args.status} message={args.message} />
		</AppShell>
	{/snippet}
</Story>
