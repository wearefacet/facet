<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect } from 'storybook/test';
	import DoctypeBadge from './DoctypeBadge.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/DoctypeBadge',
		component: DoctypeBadge,
		tags: ['autodocs'],
		argTypes: {
			doctype: {
				control: 'select',
				options: ['invoice', 'shipment', 'contact', 'task', 'document', 'contract']
			}
		}
	});
</script>

<Story name="Invoice" args={{ label: 'Invoice', doctype: 'invoice' }} />
<Story name="Shipment" args={{ label: 'Shipment', doctype: 'shipment' }} />
<Story name="Contact" args={{ label: 'Contact', doctype: 'contact' }} />
<Story name="Task" args={{ label: 'Task', doctype: 'task' }} />
<Story name="Document" args={{ label: 'Document', doctype: 'document' }} />
<Story name="Contract" args={{ label: 'Contract', doctype: 'contract' }} />
<Story
	name="WithIcon"
	args={{ label: 'Shipment', doctype: 'shipment', icon: 'package', color: '#5B8DEF' }}
	play={async ({ canvasElement }) => {
		// A configured icon renders as an inline SVG glyph instead of the diamond.
		await expect(canvasElement.querySelector('.doctype-icon-glyph svg')).not.toBeNull();
		await expect(canvasElement.querySelector('.doctype-icon-diamond')).toBeNull();
	}}
/>
