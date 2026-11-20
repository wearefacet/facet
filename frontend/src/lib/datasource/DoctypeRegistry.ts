// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Doctype-definition registry — a `DataDriver` augmented with a
 * `doctypeDefinitions` map.
 *
 * `MockDataDriver` exposes this surface natively (definitions are registered
 * in-memory at seed time). The real `DocumentDataDriver` does not — doctype
 * definitions are stored as `core.DocType` projection documents — so this
 * adapter fetches them on construction and exposes the same map shape.
 *
 * Components authored against the mock driver (e.g. `DoctypeEditor`,
 * `DomainEditor`, `DomainSchematic`) take a `DoctypeDefinitionRegistry` so
 * they work unchanged against either driver.
 */

import type { DataDriver, Domain } from './driver.js';
import { doctypeRegistryCache } from './clientCache.js';

/**
 * A `DataDriver` that also exposes a map of doctype definitions keyed by
 * `"domain.Doctype". `MockDataDriver` satisfies this directly;
 * {@link DoctypeRegistry} adapts a real `DocumentDataDriver`.
 */
export interface DoctypeDefinitionRegistry extends DataDriver {
	readonly doctypeDefinitions: Map<string, Record<string, unknown>>;
}

/**
 * Resolves doctype definitions from a driver.
 *
 * In-memory drivers (`MockDataDriver`) expose `doctypeDefinitions`
 * synchronously — returned as-is. The HTTP-backed `DocumentDataDriver` does
 * not, so we fetch from `core.DocType` — the system doctype whose projection
 * content *is* the definition record (same shape as `definition.yml`).
 */
export async function fetchDoctypeDefinitions(
	driver: DataDriver
): Promise<Map<string, Record<string, unknown>>> {
	const maybeDriver = driver as unknown as {
		doctypeDefinitions?: Map<string, Record<string, unknown>>;
	};
	if (maybeDriver.doctypeDefinitions instanceof Map) {
		return maybeDriver.doctypeDefinitions;
	}

	const result = await driver.domain('core').doctype('DocType').list({ items: 500 });
	const map = new Map<string, Record<string, unknown>>();
	for (const item of result.data) {
		const domain = item.data.domain as string | undefined;
		const doctype = item.data.doctype as string | undefined;
		if (!domain || !doctype) continue;
		map.set(`${domain}.${doctype}`, item.data as Record<string, unknown>);
	}
	return map;
}

/**
 * Adapts a `DataDriver` (real or mock) into a {@link DoctypeDefinitionRegistry}
 * by pre-fetching the doctype-definition map from `core.DocType`.
 *
 * `domain()` delegates to the underlying driver, so DataSource operations
 * (`.list()`, `.create()`, …) hit the real backend. `doctypeDefinitions` is a
 * one-time snapshot built on construction.
 */
export class DoctypeRegistry implements DoctypeDefinitionRegistry {
	readonly doctypeDefinitions = new Map<string, Record<string, unknown>>();

	constructor(private readonly driver: DataDriver) {}

	domain(name: string): Domain {
		return this.driver.domain(name);
	}

	getDoctypeDefinition(qualifiedName: string): Record<string, unknown> | undefined {
		return this.doctypeDefinitions.get(qualifiedName);
	}

	/**
	 * Builds a registry by fetching all `core.DocType` projections through the
	 * given driver. `MockDataDriver` short-circuits — its definitions are
	 * already in memory.
	 *
	 * No caching — every call fetches. Use {@link DoctypeRegistry.cached} from
	 * app code to share one snapshot across the session (60s TTL).
	 */
	static async from(driver: DataDriver): Promise<DoctypeRegistry> {
		const reg = new DoctypeRegistry(driver);
		const defs = await fetchDoctypeDefinitions(driver);
		for (const [k, v] of defs) reg.doctypeDefinitions.set(k, v);
		return reg;
	}

	/**
	 * Browser-side cached variant of {@link DoctypeRegistry.from}. Within the
	 * 60s TTL window, all callers (route loads, `buildNavModel`, `Capsule`,
	 * `QuickViewHost`, …) share the same `DoctypeRegistry` instance — killing
	 * the 4× `core.DocType?items=500` round-trips on every navigation.
	 *
	 * On the server there is no caching — `from(driver)` is called every time
	 * (see `clientCache.ts` for the SSR gating rule).
	 *
	 * Drivers that expose their definitions natively — the mock driver — skip
	 * the cache: the cached snapshot would pin the *first* caller's driver and
	 * serve its definition map to every later caller of a different driver
	 * (story files run in one shared iframe with shared module state, so each
	 * `createMockDriver()` must observe its own rows).
	 */
	static async cached(driver: DataDriver): Promise<DoctypeRegistry> {
		const native = (driver as Partial<DoctypeDefinitionRegistry>).doctypeDefinitions;
		if (native instanceof Map) return DoctypeRegistry.from(driver);
		return doctypeRegistryCache.get(() => DoctypeRegistry.from(driver)) as Promise<DoctypeRegistry>;
	}
}
