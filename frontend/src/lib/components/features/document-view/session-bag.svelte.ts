// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Session-local clone of a story `values` bag.
 *
 * DVT input components own their field in the bag: they seed it at init and
 * write on user input. A bag passed straight from `args` turns every write
 * into a deep write through the Storybook args proxy — the write lands on the
 * shared module-level initialArgs (per-test args are a shallow copy), leaks
 * into the next retry, and re-runs renderer effects that track the args tree.
 * Hand the component a clone instead. Args stay read-only and each retry
 * starts from pristine state.
 *
 * The clone is wrapped in `$state`: the controls render from the bag and
 * mutate their containers in place (StringListEditor pushes and splices the
 * array), so the bag must stay reactive — only now the proxy is rooted at the
 * session clone, not at the shared args. Top-level arrays and plain objects
 * are cloned too (one level), which severs the shared references; components
 * replace composites (MoneyInput emits a fresh object), they never mutate them
 * in place.
 */
export function sessionBag(
	values: Record<string, unknown> | undefined
): Record<string, unknown> | undefined {
	if (values === undefined) return undefined;
	const clone: Record<string, unknown> = { ...values };
	for (const key of Object.keys(clone)) {
		const v = clone[key];
		if (Array.isArray(v)) clone[key] = [...v];
		else if (v !== null && typeof v === 'object') clone[key] = { ...(v as object) };
	}
	const reactive = $state(clone);
	return reactive;
}
