// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutLoad } from './$types';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';

/**
 * Loads a `DoctypeRegistry` for the `[draftDomain]` Builder route. The registry
 * is consumed by the `DomainEditor` (architecture schematic, doctype list) and
 * by the nested `[doctype]` route's own load function.
 */
export const load: LayoutLoad = async ({ params, fetch }) => {
	const driver = new DocumentDataDriver('', fetch);
	const registry = await DoctypeRegistry.cached(driver);
	return { draftDomain: params.draftDomain, registry };
};
