<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RbacDoctypeNode from './RbacDoctypeNode.svelte';
	import RbacDoctypeTree from './RbacDoctypeTree.svelte';
	import type { DoctypeNode, ScopeValue } from './rbacModel.js';

	let {
		node,
		state,
		expanded,
		onSet,
		onToggleExpand
	}: {
		node: DoctypeNode;
		state: Record<string, Partial<Record<string, ScopeValue[]>>>;
		/** Set of qualified doctype keys currently expanded in the accordion. */
		expanded: Set<string>;
		/** Replace the scope selection for a (qualified, action) pair. */
		onSet: (qualified: string, action: string, value: ScopeValue[]) => void;
		/** Toggle the accordion open/closed state for a doctype key. */
		onToggleExpand: (qualified: string) => void;
	} = $props();

	const isOpen = $derived(expanded.has(node.qualified));
	const hasChildren = $derived(node.children.length > 0);
</script>

<RbacDoctypeNode
	{node}
	{state}
	{onSet}
	expandable={hasChildren}
	expanded={isOpen}
	onToggleExpand={() => onToggleExpand(node.qualified)}
/>

{#if hasChildren && isOpen}
	<div class="node-children" role="group">
		{#each node.children as child (child.qualified)}
			<RbacDoctypeTree node={child} {state} {expanded} {onSet} {onToggleExpand} />
		{/each}
	</div>
{/if}

<style>
	.node-children {
		display: flex;
		flex-direction: column;
	}
</style>
