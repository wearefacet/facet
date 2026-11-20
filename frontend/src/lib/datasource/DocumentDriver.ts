// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataSource } from './interface.js';
import type { Domain, DataDriver } from './driver.js';
import { DocumentDataSource } from './DocumentDataSource.js';

type FetchFn = typeof fetch;

// ── Domain implementation ─────────────────────────────────────────────────────────────────

class DocumentDomain implements Domain {
	constructor(
		private readonly baseUrl: string,
		private readonly domainName: string,
		private readonly fetchFn?: FetchFn
	) {}

	doctype<T = Record<string, unknown>>(name: string, _seedData?: T[]): DataSource<T> {
		return new DocumentDataSource<T>(this.domainName, name, this.baseUrl, this.fetchFn);
	}
}

// ── Driver implementation ──────────────────────────────────────────────────

/**
 * HTTP-backed DataDriver that talks to an Facet REST API server.
 *
 * Created with a base URL pointing to the server root
 * (e.g. `"http://localhost:3000"`). Every operation builds URLs of the form
 * `{baseUrl}/Api/{domain}/{doctype}`.
 *
 * @example
 * ```ts
 * const driver = new DocumentDataDriver("http://localhost:3000");
 *
 * // Domain-level access
 * const hr = driver.domain("hr");
 *
 * // Doctype-level access — returns a DataSource<Employee>
 * const employees = hr.doctype("Employee");
 * const list = await employees.list();
 *
 * // Chained
 * const depts = driver.domain("org").doctype("Department");
 * await depts.create({ name: "Engineering" });
 * ```
 */
export class DocumentDataDriver implements DataDriver {
	private readonly domains = new Map<string, DocumentDomain>();

	/**
	 * @param baseUrl  The server root URL (e.g. `"http://localhost:3000"`).
	 *                 Do not include `/Api` — it is appended automatically.
	 * @param fetchFn  Optional custom fetch — pass SvelteKit's `event.fetch`
	 *                 in load functions so relative URLs resolve during SSR.
	 *                 It is forwarded to `apiFetch` as `opts.fetch` so
	 *                 token refresh and 401 recovery remain active.
	 *                 When omitted, `apiFetch` uses the global `fetch`.
	 */
	constructor(
		private readonly baseUrl: string,
		private readonly fetchFn?: FetchFn
	) {}

	domain(name: string): Domain {
		let d = this.domains.get(name);
		if (!d) {
			d = new DocumentDomain(this.baseUrl, name, this.fetchFn);
			this.domains.set(name, d);
		}
		return d;
	}

	/**
	 * The HTTP driver keeps no local definition store. Callers fall back
	 * to `DoctypeRegistry.cached`.
	 */
	getDoctypeDefinition(_qualifiedName: string): Record<string, unknown> | undefined {
		return undefined;
	}
}
