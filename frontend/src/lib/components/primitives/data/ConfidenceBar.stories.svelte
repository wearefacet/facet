<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ConfidenceBar from './ConfidenceBar.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/ConfidenceBar',
		component: ConfidenceBar,
		tags: ['autodocs'],
		argTypes: {
			level: {
				control: 'select',
				options: ['hi', 'md', 'lo']
			},
			levels: {
				control: 'object'
			},
			value: {
				control: { type: 'range', min: 0, max: 100 }
			}
		}
	});
</script>

<Story name="High" args={{ value: 92 }} />
<Story name="Medium" args={{ value: 74 }} />
<Story name="Low" args={{ value: 58 }} />

<Story name="NoLabel" args={{ value: 85, showLabel: false }} />
<Story name="ExplicitLevel" args={{ value: 60, level: 'md' }} />
<Story name="Zero" args={{ value: 0 }} />
<Story name="Full" args={{ value: 100 }} />

<Story name="SolidNull" args={{ value: 72, levels: null }} />
<Story name="CustomThresholds_50_80" args={{ value: 55, levels: [0.5, 0.8] }} />
