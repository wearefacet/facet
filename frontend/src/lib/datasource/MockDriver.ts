// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataSource } from './interface.js';
import type { Domain, DataDriver } from './driver.js';
import { MockDataSource } from './MockDataSource.js';

// ── Doctype definition type ─────────────────────────────────────────────────

/**
 * A loaded fixture (doctype definition + seed documents).
 */
export interface FixtureEntity {
	domain: string;
	doctype: string;
	/** The raw definition record, or undefined for core doctypes defined in seeds. */
	definition?: Record<string, unknown>;
	/** Seed documents in `{ id, content }` format. */
	documents: { id: string; content: Record<string, unknown> }[];
}

// ── Domain implementation ──────────────────────────────────────────────────

class MockDomain implements Domain {
	private readonly doctypes = new Map<string, MockDataSource>();

	constructor(
		private readonly domainName: string,
		private readonly sharedDocs: Map<string, unknown>,
		private readonly definitions?: Map<string, Record<string, unknown>>
	) {}

	/**
	 * Return a DataSource for the given doctype.
	 *
	 * If a DataSource was already created for this doctype, the existing one
	 * is returned — all doctypes within this domain share the same global store,
	 * so data seeded through one doctype is visible to others.
	 *
	 * @param name  The doctype name (e.g. "Employee", "Department").
	 * @param seedData  Optional seed documents passed only on the first call
	 *                  for this doctype. Subsequent calls ignore this parameter.
	 */
	doctype<T = Record<string, unknown>>(name: string, seedData?: T[]): DataSource<T> {
		const existing = this.doctypes.get(name);
		if (existing) return existing as MockDataSource<T>;
		const ds = new MockDataSource<T>(
			this.domainName,
			name,
			seedData ?? [],
			this.sharedDocs,
			this.definitions
		);
		this.doctypes.set(name, ds as MockDataSource<Record<string, unknown>>);
		return ds;
	}
}

// ── Driver implementation ──────────────────────────────────────────────────

/**
 * In-memory DataDriver that stores all documents in a single shared store.
 *
 * Every domain and doctype backed by this driver shares the same underlying
 * document map, making it possible to create relationships across doctypes
 * (e.g. `hr.Employee` referencing `org.Department`) for testing Storybook
 * stories and component tests.
 *
 * The driver also holds a registry of doctype definitions loaded from fixtures,
 * enabling components that need schema information (field types, relationships,
 * computed fields) to look them up at runtime.
 *
 * @example
 * ```ts
 * const driver = new MockDataDriver();
 *
 * // Seed departments
 * const deptDs = driver.domain("org").doctype("Department");
 * await deptDs.create({ name: "Engineering" });
 * await deptDs.create({ name: "Sales" });
 *
 * // Seed employees referencing departments
 * const empDs = driver.domain("hr").doctype("Employee");
 * await empDs.create({ name: "Alice", department_id: "dept-1" });
 *
 * // List all employees — data lives in the same shared store
 * const list = await empDs.list();
 * ```
 */
export class MockDataDriver implements DataDriver {
	private readonly domains = new Map<string, MockDomain>();

	/**
	 * Shared document store. All doctypes across all domains backed by this
	 * driver write into the same map; use {@link DataSource.list} with filters
	 * to scope queries to a particular domain/doctype.
	 */
	readonly docs = new Map<string, unknown>();

	/**
	 * Registry of doctype definitions keyed by `"{domain}.{doctype}"`.
	 *
	 * Populated by {@link MockDataDriver.registerDoctype}. Components can look
	 * up schema information (field types, relationships, computed fields, etc.)
	 * at runtime via {@link MockDataDriver.getDoctypeDefinition}.
	 */
	readonly doctypeDefinitions = new Map<string, Record<string, unknown>>();

	domain(name: string): Domain {
		let d = this.domains.get(name);
		if (!d) {
			d = new MockDomain(name, this.docs, this.doctypeDefinitions);
			this.domains.set(name, d);
		}
		return d;
	}

	/**
	 * Register a doctype definition for the given domain and doctype.
	 *
	 * This makes schema metadata available to components that need to inspect
	 * field types, actions, children, or other definition-level information.
	 *
	 * @param domain  The domain name (e.g. "hr", "crm").
	 * @param doctype  The doctype name (e.g. "Candidate", "Company").
	 * @param definition  The raw definition record (from a fixture or seed).
	 */
	registerDoctype(domain: string, doctype: string, definition: Record<string, unknown>): void {
		this.doctypeDefinitions.set(`${domain}.${doctype}`, definition);
	}

	/**
	 * Look up a doctype definition by qualified name.
	 *
	 * @param qualifiedName  The qualified doctype name, e.g. `"hr.Candidate"`.
	 * @returns The definition record, or `undefined` if not registered.
	 */
	getDoctypeDefinition(qualifiedName: string): Record<string, unknown> | undefined {
		return this.doctypeDefinitions.get(qualifiedName);
	}
}
