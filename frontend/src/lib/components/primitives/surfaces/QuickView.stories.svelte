<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import QuickView from './QuickView.svelte';
	import DocumentViewTemplate from '../../features/document-view/DocumentViewTemplate.svelte';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/QuickView',
		component: QuickView,
		tags: ['autodocs'],
		argTypes: { open: { control: 'boolean' } }
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	const employeeData: Record<string, unknown> = {
		employee_id: 'EMP-0042',
		first_name: 'Jane',
		last_name: 'Doe',
		email: 'jane.doe@company.com',
		email_label: 'jane.doe@company.com',
		phone: '+1-555-0123',
		department: 'Engineering',
		title: 'Senior Software Engineer',
		manager: 'Sarah Connor',
		hire_date: '2022-03-15',
		status: 'active',
		employment_type: 'full-time',
		avatar_url: 'https://api.dicebear.com/9.x/notionists/svg?seed=Jane',
		salary_range: '$120k-$150k',
		address: {
			street: '456 Oak Ave',
			city: 'San Francisco',
			state: 'CA',
			zip: '94102',
			country: 'USA'
		},
		skills: [
			{ name: 'TypeScript', level: 'expert' },
			{ name: 'Crystal', level: 'advanced' },
			{ name: 'PostgreSQL', level: 'intermediate' }
		],
		emergency_contacts: [{ name: 'John Doe', relationship: 'Spouse', phone: '+1-555-0199' }]
	};
</script>

<Story name="Default">
	{#snippet template()}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<QuickView open>
				{#snippet header()}
					<span style="font-weight:600;">INV-0486</span>
				{/snippet}
				{#snippet title()}
					<h2
						style="margin:0 0 8px;font-family:var(--font-display);font-size:18px;letter-spacing:-0.01em"
					>
						Kuehne + Nagel — € 28,900.00
					</h2>
				{/snippet}
				<p style="color:var(--text-2);font-size:13px;line-height:1.6">
					A generic peek drawer with a header, title, scrollable body, and footer.
				</p>
				{#snippet footer()}
					<button class="btn pri sm">Edit</button>
					<button class="btn sm">Open full page</button>
					<span class="sp"></span>
				{/snippet}
			</QuickView>
		</div>
	{/snippet}
</Story>

<Story name="WithDVT">
	{#snippet template()}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<QuickView open>
				{#snippet header()}
					<span class="cap invoice"><span class="fx"></span>EMP-0042</span>
				{/snippet}
				{#snippet title()}
					<h2
						style="margin:0 0 8px;font-family:var(--font-display);font-size:18px;letter-spacing:-0.01em"
					>
						Jane Doe
					</h2>
					<span class="badge ok">Active</span>
				{/snippet}
				<DocumentViewTemplate
					template={{
						type: 'tabs' as const,
						tabs: [
							{
								type: 'tab' as const,
								label: 'Identity',
								children: [
									{
										type: 'grid' as const,
										layout: '1 3',
										children: [
											{
												type: 'col' as const,
												children: [
													{
														type: 'image' as const,
														src: '$avatar_url',
														variant: 'avatar',
														alt: 'Employee photo'
													}
												]
											},
											{
												type: 'col' as const,
												children: [
													{ type: 'title' as const, value: '$first_name $last_name', level: 1 },
													{ type: 'capsule' as const, value: '$employee_id' },
													{ type: 'hr' as const },
													{ type: 'field' as const, label: 'Employee ID', value: '$employee_id' },
													{
														type: 'field' as const,
														label: 'Full Name',
														value: '$first_name $last_name'
													},
													{
														type: 'field' as const,
														label: 'Email',
														value: '$email',
														children: [
															{
																type: 'email' as const,
																label: '$email_label',
																href: 'mailto:$email'
															}
														]
													},
													{ type: 'field' as const, label: 'Phone', value: '$phone' }
												]
											}
										]
									}
								]
							},
							{
								type: 'tab' as const,
								label: 'Employment',
								children: [
									{ type: 'field' as const, label: 'Department', value: '$department' },
									{ type: 'field' as const, label: 'Title', value: '$title' },
									{ type: 'field' as const, label: 'Manager', value: '$manager' },
									{ type: 'field' as const, label: 'Hire Date', value: '$hire_date' },
									{ type: 'field' as const, label: 'Status', value: '$status' },
									{ type: 'field' as const, label: 'Type', value: '$employment_type' },
									{ type: 'field' as const, label: 'Salary Range', value: '$salary_range' }
								]
							},
							{
								type: 'tab' as const,
								label: 'Address',
								children: [
									{
										type: 'object' as const,
										field: 'address',
										children: [
											{ type: 'field' as const, label: 'Street', value: '$street' },
											{ type: 'field' as const, label: 'City', value: '$city' },
											{ type: 'field' as const, label: 'State', value: '$state' },
											{ type: 'field' as const, label: 'ZIP', value: '$zip' },
											{ type: 'field' as const, label: 'Country', value: '$country' }
										]
									}
								]
							},
							{
								type: 'tab' as const,
								label: 'Skills',
								children: [
									{
										type: 'array' as const,
										field: 'skills',
										children: [
											{ type: 'field' as const, label: 'Skill', value: '$name' },
											{ type: 'field' as const, label: 'Level', value: '$level' }
										]
									}
								]
							}
						]
					}}
					document={doc(employeeData)}
				/>
				{#snippet footer()}
					<button class="btn pri sm">Edit</button>
					<button class="btn sm">Open full page</button>
					<span class="sp"></span>
				{/snippet}
			</QuickView>
		</div>
	{/snippet}
</Story>
