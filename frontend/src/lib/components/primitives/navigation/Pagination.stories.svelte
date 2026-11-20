<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import Pagination from './Pagination.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Navigation/Pagination',
		component: Pagination,
		tags: ['autodocs'],
		args: {
			onchange: fn()
		}
	});
</script>

<Story name="SinglePage" args={{ current: 1, total: 1 }} />
<Story name="FirstPage" args={{ current: 1, total: 10 }} />
<Story name="MiddlePage" args={{ current: 5, total: 10 }} />
<Story name="LastPage" args={{ current: 10, total: 10 }} />
<Story name="SmallSet" args={{ current: 3, total: 5 }} />
