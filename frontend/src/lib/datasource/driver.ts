// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataSource } from './interface.js';

/**
 * A Domain represents a logical grouping of doctypes (e.g. "hr", "org").
 *
 * Created via {@link DataDriver.domain}. Use {@link Domain.doctype} to
 * obtain a {@link DataSource} scoped to a specific doctype within this domain.
 */
export interface Domain {
	/**
	 * Return a {@link DataSource} for the given doctype name.
	 *
	 * @param name  The doctype name (e.g. "Employee", "Department").
	 * @param seedData  Optional seed documents. Only used by mock
	 *                  implementations; the real backend ignores this.
	 */
	doctype<T = Record<string, unknown>>(name: string, seedData?: T[]): DataSource<T>;
}

/**
 * A DataDriver is the top-level entry-point for accessing documents.
 *
 * It knows how to reach a particular backend server (or an in-memory store
 * for testing) and provides {@link Domain} objects by name.
 *
 * @example
 * ```ts
 * const driver = new DocumentDataDriver("http://localhost:3000");
 * const ds = driver.domain("hr").doctype("Employee");
 * const list = await ds.list();
 * ```
 */
export interface DataDriver {
	/**
	 * Return a {@link Domain} by name.
	 *
	 * @param name  The domain name (e.g. "hr", "org", "crm").
	 */
	domain(name: string): Domain;

	/**
	 * Return the doctype definition this driver holds locally, keyed by
	 * qualified name.
	 *
	 * Returns `undefined` when the driver keeps no local definition store, or
	 * when it holds no definition for the name. Callers then load definitions
	 * through `DoctypeRegistry.cached`, which serves drivers with and without
	 * a local store.
	 *
	 * @param qualifiedName  The qualified doctype name, e.g. "hr.Candidate".
	 */
	getDoctypeDefinition(qualifiedName: string): Record<string, unknown> | undefined;
}
