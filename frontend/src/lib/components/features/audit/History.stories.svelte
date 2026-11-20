<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import History from './History.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DocumentRef, DataSource } from '$lib/datasource/interface.js';
	import type { DataDriver, Domain } from '$lib/datasource/driver.js';
	import type {
		HistoryParams,
		HistoryResponse,
		MutationRecord,
		RollbackResponse
	} from '$lib/datasource/types.js';
	import { SvelteMap } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';

	const { Story } = defineMeta({
		title: 'Components/Features/Audit/History',
		component: History,
		tags: ['autodocs'],
		argTypes: {
			pageSize: { control: 'number' }
		}
	});

	interface Employee {
		name: string;
		status: 'active' | 'inactive' | 'terminated';
		job_title: string;
		department: string;
		salary: number;
	}

	// Build a driver with a realistic audit trail for one Employee document:
	// create → promotion → department move. Each mutation is recorded by the
	// mock so the trail mirrors a real session.
	async function buildEmployeeTrail(): Promise<{
		driver: MockDataDriver;
		docRef: DocumentRef<Employee>;
	}> {
		const driver = new MockDataDriver();
		const ds = driver.domain('hr').doctype<Employee>('Employee');

		const created = await ds.create({
			name: 'Alice Dupont',
			status: 'active',
			job_title: 'Software Engineer',
			department: 'Engineering',
			salary: 95000
		});

		const ref = ds.doc(created.meta.id);

		await ref.update({
			job_title: 'Senior Software Engineer',
			salary: 110000
		});

		await ref.update({ department: 'Platform' });

		return { driver, docRef: ref as DocumentRef<Employee> };
	}

	// A second trail that includes a soft-delete so the timeline shows the
	// `delete` action type.
	async function buildDeletedTrail(): Promise<{
		driver: MockDataDriver;
		docRef: DocumentRef<Employee>;
	}> {
		const driver = new MockDataDriver();
		const ds = driver.domain('hr').doctype<Employee>('Employee');

		const created = await ds.create({
			name: 'Marc Lavigne',
			status: 'active',
			job_title: 'Designer',
			department: 'Product',
			salary: 82000
		});

		const ref = ds.doc(created.meta.id);

		await ref.update({ status: 'inactive' });

		await ref.delete();

		return { driver, docRef: ref as DocumentRef<Employee> };
	}

	/** Generate a fake ULID-like string for use in fixture data. */
	let _ctr = 0;
	function fakeId(prefix: string): string {
		_ctr += 1;
		const ts = Date.now().toString(36).toUpperCase().padStart(10, '0').slice(-10);
		const n = _ctr.toString(36).toUpperCase().padStart(6, '0');
		return `${prefix}${ts}${n}`;
	}

	/**
	 * A minimal fake `DocumentRef` that returns a hand-built trail covering every
	 * History code branch: create, set with array paths, unset, long-text
	 * patch, custom action, snapshot (rollback), and delete.
	 *
	 * Only `history()` is exercised by the stories; other methods reject.
	 */
	function fixtureRef(trail: MutationRecord[]): DocumentRef<Record<string, unknown>> {
		const ref: DocumentRef<Record<string, unknown>> = {
			show: () => Promise.reject(new Error('not implemented in fixture')),
			update: () => Promise.reject(new Error('not implemented in fixture')),
			delete: () => Promise.reject(new Error('not implemented in fixture')),
			action: () => Promise.reject(new Error('not implemented in fixture')),
			invalidate: () => {},
			history: (params?: HistoryParams) => {
				let items = [...trail];
				const sort = params?.sort ?? ['-emitted_at'];
				const desc = sort.some((s) => s === '-emitted_at' || s === '-idx');
				const ascIdx = sort.some((s) => s === 'idx' || s === 'emitted_at');
				items.sort((a, b) => (desc ? b.idx - a.idx : ascIdx ? a.idx - b.idx : b.idx - a.idx));
				return Promise.resolve({
					data: items,
					meta: { count: items.length, more: false }
				} as HistoryResponse);
			},
			rollback: (mutationId: string) =>
				Promise.reject(new Error(`rollback not implemented in fixture (target=${mutationId})`)),
			restore: () => Promise.reject(new Error('restore not implemented in fixture')),
			backrefs: () => Promise.reject(new Error('backrefs not implemented in fixture')),
			children: <C = Record<string, unknown>,>(_relName: string): DataSource<C> =>
				Promise.reject(new Error('not implemented in fixture')) as unknown as DataSource<C>,
			sidecars: <C = Record<string, unknown>,>(_segment: string): DataSource<C> =>
				Promise.reject(new Error('not implemented in fixture')) as unknown as DataSource<C>
		};
		return ref;
	}

	function buildRichTrail(): DocumentRef<Record<string, unknown>> {
		const baseTime = Date.now();
		const ts = (offsetMs: number) => new Date(baseTime + offsetMs).toISOString();
		const docId = fakeId('01DOC');
		const mutations: MutationRecord[] = [];
		let idx = 0;
		const mk = (
			action: MutationRecord['action'],
			args: Record<string, unknown>,
			cause: { kind: MutationRecord['cause_kind']; event?: string | null } | null = null,
			offsetMs = idx * 60_000
		): MutationRecord => {
			idx += 1;
			const id = fakeId('01MUT');
			return {
				id,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx,
				action,
				actioner_id: 'system',
				arguments: args,
				channel: 'session',
				cause_kind: cause?.kind ?? 'request',
				cause_event: cause?.event ?? null,
				cause_trace: id,
				emitted_at: ts(offsetMs)
			};
		};

		// 1. Create
		mutations.push(
			mk('create', {
				content: { name: 'Élise Martin', status: 'active', job_title: 'Engineer', salary: 88000 }
			})
		);

		// 2. Update — set with array paths + a patch on a long string field.
		mutations.push(
			mk('update', {
				diff: {
					set: [
						{ path: ['job_title'], value: 'Senior Engineer' },
						{ path: ['salary'], value: 102000 },
						{
							path: ['bio'],
							patch: {
								hunks: [
									{
										old_start: 1,
										old_count: 2,
										new_start: 1,
										new_count: 3,
										lines: [' context line\n', '-old line\n', '+new line\n', '+another new line\n']
									}
								]
							}
						}
					],
					unset: []
				}
			})
		);

		// 3. Update — unset a field (array path), set a nested value.
		mutations.push(
			mk('update', {
				diff: {
					set: [{ path: ['/department'], value: 'Platform' }],
					unset: [['temporary_flag']]
				}
			})
		);

		// 4. Update driven by an action — same `diff` shape as a regular update,
		//    but the cause carries the action's resolved event name (past tense).
		mutations.push(
			mk(
				'update',
				{
					diff: {
						set: [
							{ path: ['job_title'], value: 'Lead Engineer' },
							{ path: ['salary'], value: 118000 }
						],
						unset: []
					}
				},
				{ kind: 'action', event: 'promoted' }
			)
		);

		// 5. Snapshot — produced by a rollback. The cause kind is `rollback`.
		mutations.push(
			mk(
				'snapshot',
				{
					content: {
						name: 'Élise Martin',
						status: 'active',
						job_title: 'Senior Engineer',
						salary: 102000
					}
				},
				{ kind: 'rollback', event: 'rolled_back' }
			)
		);

		// 6. Delete
		mutations.push(mk('delete', {}));

		return fixtureRef(mutations);
	}

	/** A full `RollbackResponse` for stubs — only `mut_id` and `content` are
	 * read by the History component. */
	function stubRollbackResponse(mutationId: string): RollbackResponse {
		return {
			id: '01STUB',
			domain: 'hr',
			doc_type: 'Employee',
			mut_id: mutationId,
			content: {},
			created_at: new Date(0).toISOString()
		};
	}

	/**
	 * Aggregate-mode fixture: one parent (`Employee`) trail merged with one
	 * child doctype (`Task`) trail — the shape `?include=children` returns.
	 *
	 * Rows carry `display_name` except one (exercises the short-`doc_id`
	 * fallback badge). The parent ref's `history()` sorts by `emitted_at` —
	 * the backend merge order — because `idx` is per-document and would
	 * interleave the two streams wrongly.
	 *
	 * Returns the child rollback spy so a play can assert that a child-row
	 * revert routes to the child ref, not the parent's.
	 */
	function buildMixedTrail(): {
		ref: DocumentRef<Record<string, unknown>>;
		driver: DataDriver;
		childRollback: ReturnType<typeof fn>;
	} {
		const baseTime = Date.now();
		const ts = (offsetMs: number) => new Date(baseTime + offsetMs).toISOString();
		const parentId = fakeId('01PAR');
		const childLabeledId = fakeId('01TKA');
		const childBareId = fakeId('01TKB');
		const childRollback = fn((_mutationId: string) =>
			Promise.resolve(stubRollbackResponse(_mutationId))
		);

		let seq = 0;
		// `idx` counts per document — parent and child streams each start at 1.
		// untrack: the mock builder runs inside play functions / effects — a
		// tracked read + the `set` write would re-run the caller.
		const idxCounters = untrack(() => new SvelteMap<string, number>());
		const nextIdx = (docId: string): number => {
			return untrack(() => {
				const n = (idxCounters.get(docId) ?? 0) + 1;
				idxCounters.set(docId, n);
				return n;
			});
		};
		const mk = (over: {
			action: MutationRecord['action'];
			args?: Record<string, unknown>;
			doc_type?: string;
			doc_id?: string;
			display_name?: string | null;
		}): MutationRecord => {
			seq += 1;
			const id = fakeId('01MUT');
			const docType = over.doc_type ?? 'Employee';
			const docId = over.doc_id ?? parentId;
			return {
				id,
				domain: 'hr',
				doc_type: docType,
				doc_id: docId,
				idx: nextIdx(docId),
				action: over.action,
				actioner_id: 'system',
				arguments: over.args ?? {},
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: id,
				emitted_at: ts(seq * 60_000),
				display_name: over.display_name === undefined ? null : over.display_name
			};
		};

		// Oldest → newest. The child doctype is `Task`; the parent is `Employee`.
		const mutations: MutationRecord[] = [
			mk({ action: 'create', args: { content: { name: 'Élise Martin' } } }),
			mk({
				action: 'create',
				args: { content: { title: 'Fix login bug' } },
				doc_type: 'Task',
				doc_id: childLabeledId,
				display_name: 'Fix login bug'
			}),
			mk({
				action: 'update',
				args: { diff: { set: [{ path: ['title'], value: 'Fix signup bug' }], unset: [] } },
				doc_type: 'Task',
				doc_id: childLabeledId,
				display_name: 'Fix login bug'
			}),
			// No display_name — the badge falls back to a short doc_id.
			mk({
				action: 'create',
				args: { content: { title: 'Write docs' } },
				doc_type: 'Task',
				doc_id: childBareId,
				display_name: null
			}),
			mk({
				action: 'delete',
				doc_type: 'Task',
				doc_id: childLabeledId,
				display_name: 'Fix login bug'
			}),
			mk({
				action: 'update',
				args: { diff: { set: [{ path: ['status'], value: 'inactive' }], unset: [] } }
			})
		];

		const ref: DocumentRef<Record<string, unknown>> = {
			show: () => Promise.reject(new Error('not implemented in fixture')),
			update: () => Promise.reject(new Error('not implemented in fixture')),
			delete: () => Promise.reject(new Error('not implemented in fixture')),
			action: () => Promise.reject(new Error('not implemented in fixture')),
			invalidate: () => {},
			history: (_params?: HistoryParams) => {
				const items = [...mutations].sort((a, b) => b.emitted_at.localeCompare(a.emitted_at));
				return Promise.resolve({
					data: items,
					meta: { count: items.length, more: false }
				} as HistoryResponse);
			},
			rollback: (mutationId: string) =>
				Promise.reject(new Error(`rollback not implemented in fixture (target=${mutationId})`)),
			restore: () => Promise.reject(new Error('restore not implemented in fixture')),
			backrefs: () => Promise.reject(new Error('backrefs not implemented in fixture')),
			children: <C = Record<string, unknown>,>(_relName: string): DataSource<C> =>
				Promise.reject(new Error('not implemented in fixture')) as unknown as DataSource<C>,
			sidecars: <C = Record<string, unknown>,>(_segment: string): DataSource<C> =>
				Promise.reject(new Error('not implemented in fixture')) as unknown as DataSource<C>
		};

		// A spy driver: every `doc()` resolves to one ref whose rollback is the
		// spy — the play asserts a child-row revert routes through it.
		const childDocRef = {
			show: () => Promise.reject(new Error('not implemented in spy driver')),
			update: () => Promise.reject(new Error('not implemented in spy driver')),
			delete: () => Promise.reject(new Error('not implemented in spy driver')),
			action: () => Promise.reject(new Error('not implemented in spy driver')),
			history: () => Promise.reject(new Error('not implemented in spy driver')),
			rollback: childRollback,
			restore: () => Promise.reject(new Error('not implemented in spy driver')),
			children: () => {
				throw new Error('not implemented in spy driver');
			},
			sidecars: () => {
				throw new Error('not implemented in spy driver');
			}
		} as unknown as DocumentRef<Record<string, unknown>>;
		const childSource = { doc: () => childDocRef } as unknown as DataSource<
			Record<string, unknown>
		>;
		const childDomain = { doctype: () => childSource } as unknown as Domain;
		const driver: DataDriver = { domain: () => childDomain, getDoctypeDefinition: () => undefined };

		return { ref, driver, childRollback };
	}

	// Bare `iam.Account` id shapes — 26-char Crockford base32 ULIDs. The
	// first is seeded as an account document; the second stays unknown so the
	// play can assert the raw-id fallback.
	const ACCOUNT_ULID = '01HAAAAAAAAAAAAAAAAAAAAAAA';
	const UNKNOWN_ULID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';

	/**
	 * A trail whose rows are recorded by an account (bare ULID actioner) and
	 * by the `system` principal — the two shapes the actor label resolver
	 * tells apart. The driver exposes the `iam.Account` row one ULID points
	 * at; the other ULID has no row (raw-id fallback).
	 */
	function buildActorTrail(): {
		ref: DocumentRef<Record<string, unknown>>;
		driver: MockDataDriver;
	} {
		const baseTime = Date.now();
		const ts = (offsetMs: number) => new Date(baseTime + offsetMs).toISOString();
		const docId = fakeId('01DOC');
		const createId = fakeId('01MUT');
		const updateId = fakeId('01MUT');
		const unknownId = fakeId('01MUT');
		const mutations: MutationRecord[] = [
			{
				id: unknownId,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx: 3,
				action: 'update',
				actioner_id: UNKNOWN_ULID,
				arguments: {
					diff: { set: [{ path: ['department'], value: 'Platform' }], unset: [] }
				},
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: unknownId,
				emitted_at: ts(120_000)
			},
			{
				id: updateId,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx: 2,
				action: 'update',
				actioner_id: ACCOUNT_ULID,
				arguments: {
					diff: { set: [{ path: ['status'], value: 'inactive' }], unset: [] }
				},
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: updateId,
				emitted_at: ts(60_000)
			},
			{
				id: createId,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx: 1,
				action: 'create',
				actioner_id: 'system',
				arguments: { content: { name: 'Élise Martin' } },
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: createId,
				emitted_at: ts(0)
			}
		];

		const driver = new MockDataDriver();
		driver
			.domain('iam')
			.doctype('Account', [{ id: ACCOUNT_ULID, name: 'Kim Patel', email: 'kim@acme.com' }]);

		return { ref: fixtureRef(mutations), driver };
	}

	/**
	 * A three-mutation trail covering the provenance badge: a plain `request`
	 * create, an assistant-caused update (what a workspace-assistant write
	 * looks like — the caller's own account, cause kind `assistant`), and a
	 * second plain update. Also serves the controlled-selection and
	 * missing-mutation stories.
	 */
	function buildCauseTrail(): {
		ref: DocumentRef<Record<string, unknown>>;
		createId: string;
		assistantId: string;
		plainId: string;
	} {
		const baseTime = Date.now();
		const ts = (offsetMs: number) => new Date(baseTime + offsetMs).toISOString();
		const docId = fakeId('01DOC');
		let idx = 0;
		const mk = (
			action: MutationRecord['action'],
			args: Record<string, unknown>,
			causeKind: MutationRecord['cause_kind'] = 'request'
		): MutationRecord => {
			idx += 1;
			const id = fakeId('01MUT');
			return {
				id,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx,
				action,
				actioner_id: ACCOUNT_ULID,
				arguments: args,
				channel: 'session',
				cause_kind: causeKind,
				cause_event: null,
				cause_trace: id,
				emitted_at: ts(idx * 60_000)
			};
		};

		const create = mk('create', { content: { name: 'Ada' } });
		const assistant = mk(
			'update',
			{ diff: { set: [{ path: ['name'], value: 'Ada Lovelace' }], unset: [] } },
			'assistant'
		);
		const plain = mk('update', {
			diff: { set: [{ path: ['status'], value: 'active' }], unset: [] }
		});

		return {
			ref: fixtureRef([create, assistant, plain]),
			createId: create.id,
			assistantId: assistant.id,
			plainId: plain.id
		};
	}

	/** A trail that exercises the detail header's variant rows: the mcp and
	 * api-key channel chips (with their sub-labels), an action cause chip
	 * (with `cause_name`), and a set/unset stats line. */
	function buildHeaderTrail(): {
		ref: DocumentRef<Record<string, unknown>>;
		mcpId: string;
		apiKeyId: string;
		actionId: string;
	} {
		const baseTime = Date.now();
		const ts = (offsetMs: number) => new Date(baseTime + offsetMs).toISOString();
		const docId = fakeId('01DOC');
		const keyRow = '01JKEY00000000000000000A91F';
		let idx = 0;
		const mk = ({
			args,
			...overrides
		}: Partial<MutationRecord> & { args: Record<string, unknown> }): MutationRecord => {
			idx += 1;
			const id = fakeId('01MUT');
			return {
				id,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx,
				action: 'update',
				actioner_id: ACCOUNT_ULID,
				arguments: args,
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: id,
				emitted_at: ts(idx * 60_000),
				...overrides
			};
		};

		const create = mk({ action: 'create', args: { content: { name: 'Ada' } } });
		const viaMcp = mk({
			args: { diff: { set: [{ path: ['name'], value: 'Ada Lovelace' }], unset: [] } },
			channel: 'mcp',
			acting_role: 'admin'
		});
		const viaApiKey = mk({
			args: { diff: { set: [{ path: ['status'], value: 'active' }], unset: [['note']] } },
			channel: 'api_key',
			api_key: keyRow
		});
		const viaAction = mk({
			args: {
				diff: {
					set: [
						{ path: ['job_title'], value: 'Lead Engineer' },
						{ path: ['salary'], value: 118000 }
					],
					unset: []
				}
			},
			cause_kind: 'action',
			cause_event: 'promoted',
			cause_name: 'promote_deal'
		});

		return {
			ref: fixtureRef([create, viaMcp, viaApiKey, viaAction]),
			mcpId: viaMcp.id,
			apiKeyId: viaApiKey.id,
			actionId: viaAction.id
		};
	}

	/**
	 * A paginated fixture: `history()` serves fixed-size pages with a `more`
	 * flag, so the deep-link walk (a controlled selection naming a mutation
	 * beyond the first page) has real work to do.
	 */
	function buildPagedTrail(pageSize: number): {
		ref: DocumentRef<Record<string, unknown>>;
		oldestId: string;
	} {
		const baseTime = Date.now();
		const docId = fakeId('01DOC');
		const trail: MutationRecord[] = [];
		for (let i = 1; i <= pageSize * 2 + 3; i += 1) {
			const id = fakeId('01MUT');
			trail.push({
				id,
				domain: 'hr',
				doc_type: 'Employee',
				doc_id: docId,
				idx: i,
				action: i === 1 ? 'create' : 'update',
				actioner_id: ACCOUNT_ULID,
				arguments:
					i === 1
						? { content: { name: 'Paginated' } }
						: { diff: { set: [{ path: ['n'], value: i }], unset: [] } },
				channel: 'session',
				cause_kind: 'request',
				cause_event: null,
				cause_trace: id,
				emitted_at: new Date(baseTime + i * 60_000).toISOString()
			});
		}

		const ref: DocumentRef<Record<string, unknown>> = {
			...fixtureRef(trail),
			history: (params?: HistoryParams) => {
				const size = params?.items ?? pageSize;
				const page = params?.page ?? 1;
				const sorted = [...trail].sort((a, b) => b.idx - a.idx);
				const start = (page - 1) * size;
				return Promise.resolve({
					data: sorted.slice(start, start + size),
					meta: { count: trail.length, more: start + size < trail.length }
				} as HistoryResponse);
			}
		};
		const oldest = trail.reduce((a, b) => (a.idx < b.idx ? a : b));
		return { ref, oldestId: oldest.id };
	}

	/** Minimal delay helper — lets bits-ui restore the body's pointer-events
	 *  after a modal dialog closes (restored asynchronously on the next tick). */
	function sleep(ms: number): Promise<void> {
		return new Promise((r) => setTimeout(r, ms));
	}

	/**
	 * The cause trail with a rollback spy on the parent ref — the revert-dialog
	 * plays assert against the spy. Three mutations: `#2` (the assistant
	 * update) is revertable, `#3` is the newest (button disabled).
	 */
	function buildRevertTrail(): {
		ref: DocumentRef<Record<string, unknown>>;
		rollback: ReturnType<typeof fn>;
		targetId: string;
	} {
		const base = buildCauseTrail();
		const rollback = fn((mutationId: string) => Promise.resolve(stubRollbackResponse(mutationId)));
		const ref: DocumentRef<Record<string, unknown>> = { ...base.ref, rollback };
		return { ref, rollback, targetId: base.assistantId };
	}
</script>

<script lang="ts">
	import { onMount, untrack } from 'svelte';

	let auditRef: DocumentRef<Employee> | null = $state(null);
	let deletedRef: DocumentRef<Employee> | null = $state(null);
	let richRef: DocumentRef<Record<string, unknown>> | null = $state(null);
	let mixed: ReturnType<typeof buildMixedTrail> | null = $state(null);
	let actorTrail: ReturnType<typeof buildActorTrail> | null = $state(null);
	let causeTrail: ReturnType<typeof buildCauseTrail> | null = $state(null);
	let headerTrail: ReturnType<typeof buildHeaderTrail> | null = $state(null);
	let pagedTrail: ReturnType<typeof buildPagedTrail> | null = $state(null);
	let revertTrail: ReturnType<typeof buildRevertTrail> | null = $state(null);
	// Controlled selection owned by the story's parent — the same shape the
	// history page keeps in `?mutation=`.
	let controlledSelected: string | undefined = $state(undefined);
	const MISSING_MUTATION_ID = '01ZZZZZZZZZZZZZZZZZZZZZZZZ';

	onMount(async () => {
		const main = await buildEmployeeTrail();
		auditRef = main.docRef;
		const deleted = await buildDeletedTrail();
		deletedRef = deleted.docRef;
		richRef = buildRichTrail();
		mixed = buildMixedTrail();
		actorTrail = buildActorTrail();
		causeTrail = buildCauseTrail();
		headerTrail = buildHeaderTrail();
		pagedTrail = buildPagedTrail(50);
		revertTrail = buildRevertTrail();
	});

	// Feedback banner for the revert story.
	let revertNotice: string | null = $state(null);

	// Controlled selection + `onSelect` spy for the revert-reload stability
	// story — the same shape the history page keeps in `?mutation=`.
	let revertControlledSel: string | undefined = $state(undefined);
	const revertOnSelect = fn();
</script>

<Story name="Default">
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if auditRef}
					<History documentRef={auditRef} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story name="IncludesDelete">
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if deletedRef}
					<History documentRef={deletedRef} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story name="RichTrail">
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:860px;max-width:100%">
				{#if richRef}
					<History documentRef={richRef} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story name="WithRevertFeedback">
	{#snippet template()}
		<div
			style="height:80vh;min-height:560px;display:flex;flex-direction:column;gap:12px;padding:24px;background:var(--sunken)"
		>
			<div style="width:760px;max-width:100%;flex:1;min-height:0">
				{#if auditRef}
					<History documentRef={auditRef} onRevert={(r) => (revertNotice = r.mutationId)} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
			{#if revertNotice}
				<div class="revert-banner">
					✓ Reverted · snapshot
					<code>{revertNotice.slice(0, 14)}…</code>
					appended to the audit trail.
				</div>
			{/if}
		</div>
	{/snippet}
</Story>

<Story name="Empty">
	{#snippet template()}
		<div style="height:60vh;min-height:400px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				<History documentRef={null} emptyMessage="No history available." />
			</div>
		</div>
	{/snippet}
</Story>

<Story name="MixedTimeline">
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:860px;max-width:100%">
				{#if mixed}
					<History
						documentRef={mixed.ref}
						parentDocType="Employee"
						driver={mixed.driver}
						includeChildren
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="ChildRowBadgeRendering"
	play={async () => {
		const canvas = within(document.body);
		// Child rows carry a badge: doctype name + the document label.
		await waitFor(() => expect(canvas.getAllByText('Task').length).toBeGreaterThan(0));
		await expect(canvas.getAllByText('Fix login bug').length).toBe(3);
		// The parent's own rows render no badge.
		await expect(canvas.getAllByText('Document deleted').length).toBe(1);
		// A child row without display_name falls back to a short doc_id.
		const bare = canvas.getAllByText(/^01TKB/);
		await expect(bare.length).toBeGreaterThan(0);
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:860px;max-width:100%">
				{#if mixed}
					<History
						documentRef={mixed.ref}
						parentDocType="Employee"
						driver={mixed.driver}
						includeChildren
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="ChildRowRevertTargetsChildRef"
	play={async () => {
		const canvas = within(document.body);
		// Select the child's `update` row — the middle of the three labeled
		// Task rows (newest first: delete, update, create).
		let labels: HTMLElement[] = [];
		await waitFor(() => {
			labels = canvas.getAllByText('Fix login bug');
			expect(labels.length).toBe(3);
		});
		const updateRow = labels[1].closest('button');
		expect(updateRow).not.toBeNull();
		await userEvent.click(updateRow as HTMLButtonElement);

		// Revert routes through the child ref resolved from the driver —
		// never through the page's parent documentRef. The confirm dialog
		// gates the revert; confirming fires the child rollback once.
		const btn = canvas.getByRole('button', { name: 'Revert to this version' });
		await waitFor(() => expect(btn).toBeEnabled());
		await userEvent.click(btn);
		await waitFor(() => expect(canvas.getByText('Confirm rollback')).toBeVisible());
		await expect(canvas.getByText(/A new snapshot mutation will be written/)).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Roll back' }));
		await waitFor(() => expect(mixed?.childRollback).toHaveBeenCalledTimes(1));
		// Close the dialog so the shared storybook iframe is clean for the next
		// story (a modal sets `pointer-events: none` on body while open).
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:860px;max-width:100%">
				{#if mixed}
					<History
						documentRef={mixed.ref}
						parentDocType="Employee"
						driver={mixed.driver}
						includeChildren
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="DeleteRowShowsRestoreHint"
	play={async () => {
		const canvas = within(document.body);
		// Select the child's `delete` row — the newest of the labeled rows.
		let labels: HTMLElement[] = [];
		await waitFor(() => {
			labels = canvas.getAllByText('Fix login bug');
			expect(labels.length).toBe(3);
		});
		const deleteRow = labels[0].closest('button');
		expect(deleteRow).not.toBeNull();
		await userEvent.click(deleteRow as HTMLButtonElement);

		// Revert on a delete row restores the document (N5) — the hint says
		// so, and the revert button still renders.
		await waitFor(() => expect(canvas.getByText('Revert restores the document.')).toBeVisible());
		await expect(canvas.getByRole('button', { name: 'Revert to this version' })).toBeVisible();

		// The delete row's confirm dialog uses the restore wording. Cancel
		// closes it and makes no request.
		await userEvent.click(canvas.getByRole('button', { name: 'Revert to this version' }));
		await waitFor(() =>
			expect(canvas.getByText(/state recorded by the mutation before this delete/)).toBeVisible()
		);
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await expect(mixed?.childRollback).not.toHaveBeenCalled();
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:860px;max-width:100%">
				{#if mixed}
					<History
						documentRef={mixed.ref}
						parentDocType="Employee"
						driver={mixed.driver}
						includeChildren
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="RevertDialogCancelAndConfirm"
	play={async () => {
		const canvas = within(document.body);
		// The trail lands asynchronously; #2 (the assistant update) is
		// revertable, #3 is the newest (button disabled).
		await waitFor(() => expect(canvas.getByText('via Assistant')).toBeVisible());
		const row = canvas.getByText('#2').closest('button');
		expect(row).not.toBeNull();
		await userEvent.click(row as HTMLButtonElement);
		const revertBtn = canvas.getByRole('button', { name: 'Revert to this version' });
		await waitFor(() => expect(revertBtn).toBeEnabled());

		// Cancel: the dialog closes and no rollback request is made.
		await userEvent.click(revertBtn);
		await waitFor(() => expect(canvas.getByText('Confirm rollback')).toBeVisible());
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await expect(revertTrail?.rollback).not.toHaveBeenCalled();
		// bits-ui restores the body's pointer-events after a modal closes on
		// the next tick — wait it out before the next pointer interaction.
		await sleep(50);

		// Confirm: the dialog names the target document and the mutation id,
		// states the snapshot write, and the rollback fires exactly once.
		await waitFor(async () => {
			await userEvent.click(canvas.getByRole('button', { name: 'Revert to this version' }));
		});
		await waitFor(() => expect(canvas.getByText('Confirm rollback')).toBeVisible());
		await expect(canvas.getByText(/state recorded by mutation/)).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Roll back' }));
		await waitFor(() => expect(revertTrail?.rollback).toHaveBeenCalledTimes(1));
		await expect(revertTrail?.rollback).toHaveBeenCalledWith(revertTrail!.targetId);
		// Close the dialog so the shared storybook iframe stays clean for the
		// next story (a modal sets `pointer-events: none` on body while open).
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if revertTrail}
					<History documentRef={revertTrail.ref} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="RevertReloadKeepsSelectionStable"
	play={async () => {
		const canvas = within(document.body);
		// The trail lands asynchronously, then the controlled selection (the
		// page's `?mutation=`) resolves to #2.
		await waitFor(() => expect(revertTrail).not.toBeNull());
		revertControlledSel = revertTrail!.targetId;
		await waitFor(() => expect(canvas.getByTitle(revertTrail!.targetId)).toBeVisible());
		// The selection sync notified exactly once — the initial pick.
		await expect(revertOnSelect).toHaveBeenCalledTimes(1);
		await expect(revertOnSelect.mock.calls[0][0]?.id).toBe(revertTrail!.targetId);

		// Revert through the dialog. The reload rebuilds the response object
		// and re-wraps the unchanged records in fresh proxies; the sync must
		// stay silent because the selected id did not change.
		const revertBtn = canvas.getByRole('button', { name: 'Revert to this version' });
		await userEvent.click(revertBtn);
		await waitFor(() => expect(canvas.getByText('Confirm rollback')).toBeVisible());
		await userEvent.click(canvas.getByRole('button', { name: 'Roll back' }));
		await waitFor(() => expect(revertTrail?.rollback).toHaveBeenCalledTimes(1));
		// Give the post-reload effects a beat before asserting silence.
		await sleep(50);
		await expect(revertOnSelect).toHaveBeenCalledTimes(1);
		// The selection survived the reload: one pressed row, same detail.
		await expect(canvas.getAllByRole('button', { pressed: true })).toHaveLength(1);
		await expect(canvas.getByTitle(revertTrail!.targetId)).toBeVisible();
		// Close the dialog so the shared storybook iframe stays clean for the
		// next story (a modal sets `pointer-events: none` on body while open).
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if revertTrail}
					<History
						documentRef={revertTrail.ref}
						selected={revertControlledSel}
						onSelect={revertOnSelect}
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="ActorLabelResolution"
	play={async () => {
		const canvas = within(document.body);
		// The ULID actioner resolves to the account display name.
		await waitFor(() => expect(canvas.getByText('Kim Patel')).toBeVisible());
		// The `system` principal keeps its readable raw id…
		await expect(canvas.getByText('system')).toBeVisible();
		// …an unknown ULID (no account row) falls back to the raw id…
		await expect(canvas.getByText(UNKNOWN_ULID)).toBeVisible();
		// …and the known account's bare ULID never renders.
		expect(canvas.queryByText(ACCOUNT_ULID)).toBeNull();

		// Selecting the account row shows the actor capsule in the detail pane —
		// a link to the account's document page (no QuickView host here) — and
		// the who row names the plain session channel after it.
		await userEvent.click(canvas.getByText('Kim Patel'));
		// The capsule hydrates to the same display name — now two rows carry it
		// (timeline row + detail capsule).
		await waitFor(() => expect(canvas.getAllByText('Kim Patel').length).toBe(2));
		const link = canvas.getByRole('link', { name: /Kim Patel/ });
		await expect(link.getAttribute('href')).toContain('/iam/Account/');
		// The who row: the `via` separator followed by the channel chip
		// (`session` renders as `facet`).
		await expect(canvas.getByText(m.audit_via_sep())).toBeVisible();
		await expect(canvas.getByText('facet')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if actorTrail}
					<History documentRef={actorTrail.ref} driver={actorTrail.driver} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="AssistantCauseBadge"
	play={async () => {
		const canvas = within(document.body);
		// The assistant-caused row carries the provenance badge…
		await waitFor(() => expect(canvas.getByText('via Assistant')).toBeVisible());
		// …the plain request rows carry none.
		await expect(canvas.queryByText('via Request')).toBeNull();

		// Selecting the row names the cause in the who row: the `via`
		// separator, then the Assistant chip (amber, with the Bot icon).
		const row = canvas.getByText('via Assistant').closest('button');
		expect(row).not.toBeNull();
		await userEvent.click(row as HTMLButtonElement);
		await expect(canvas.getByText(m.audit_via_sep())).toBeVisible();
		await expect(canvas.getByText('Assistant')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if causeTrail}
					<History documentRef={causeTrail.ref} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="MutationHeaderRows"
	play={async () => {
		const canvas = within(document.body);
		// Detail-pane queries scope to the aside — the timeline's summary line
		// repeats the same change counts in plain text. The aside mounts with
		// the timeline, so the helper resolves it lazily.
		const detail = () => within(document.body.querySelector('.audit-detail')!);
		// The fixtures land asynchronously, then the timeline renders.
		await waitFor(() => expect(headerTrail).not.toBeNull());
		await waitFor(() => expect(canvas.getByText('#4')).toBeVisible());

		// ── v4 · action cause ───────────────────────────────
		// The newest row: an action-driven update. The what row shows the
		// entity, the page-provided label, and the version chip; the who row
		// names the transport with the action name as the sub-label; the ref
		// row carries the id, the copy affordance, and the stats.
		const actionRow = canvas.getByText('#4').closest('button');
		expect(actionRow).not.toBeNull();
		await userEvent.click(actionRow as HTMLButtonElement);
		await expect(detail().getByText('Employee')).toBeVisible();
		await expect(detail().getByText('Élise Martin')).toBeVisible();
		await expect(detail().getByTitle('Document version 4')).toBeVisible();
		await expect(detail().getByTitle(headerTrail!.actionId)).toBeVisible();
		await expect(detail().getByText(m.audit_via_sep())).toBeVisible();
		await expect(detail().getByText('facet')).toBeVisible();
		await expect(detail().getByText('· promote_deal')).toBeVisible();
		await expect(detail().getByText('2 set')).toBeVisible();
		await expect(detail().getByRole('button', { name: 'Copy' })).toBeVisible();

		// ── v3 · api key channel ───────────────────────────────
		// The api_key channel chip carries the masked key sub-label, and the
		// stats count one set and one unset.
		const apiKeyRow = canvas.getByText('#3').closest('button');
		expect(apiKeyRow).not.toBeNull();
		await userEvent.click(apiKeyRow as HTMLButtonElement);
		await expect(detail().getByText('api_key')).toBeVisible();
		await expect(detail().getByText('· key …A91F')).toBeVisible();
		await expect(detail().getByText('1 set')).toBeVisible();
		await expect(detail().getByText('1 unset')).toBeVisible();
		await expect(detail().getByTitle('Document version 3')).toBeVisible();

		// ── v2 · mcp channel ───────────────────────────────
		// The mcp chip carries the elected acting role as its sub-label.
		const mcpRow = canvas.getByText('#2').closest('button');
		expect(mcpRow).not.toBeNull();
		await userEvent.click(mcpRow as HTMLButtonElement);
		await expect(detail().getByText('mcp')).toBeVisible();
		await expect(detail().getByText('· admin')).toBeVisible();
		await expect(detail().getByTitle('Document version 2')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if headerTrail}
					<History documentRef={headerTrail.ref} documentLabel="Élise Martin" />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="ControlledSelectionFollowsClick"
	play={async () => {
		const canvas = within(document.body);
		// The fixtures land asynchronously — wait for the create row, then reset
		// to the preselected plain update (deterministic across retries).
		await waitFor(() => expect(canvas.getByText('1 field initialized')).toBeVisible());
		controlledSelected = causeTrail!.plainId;
		await waitFor(() => expect(canvas.getAllByRole('button', { pressed: true })).toHaveLength(1));
		// The preselected row's detail shows its mutation id.
		await expect(canvas.getByTitle(causeTrail!.plainId)).toBeVisible();

		// Clicking another row reports through `onSelect`; the parent mirrors it
		// into `selected`, and the detail pane follows.
		const createRow = canvas.getAllByText('1 field initialized')[0]!.closest('button');
		expect(createRow).not.toBeNull();
		await userEvent.click(createRow as HTMLButtonElement);
		await waitFor(() => expect(canvas.getByTitle(causeTrail!.createId)).toBeVisible());
		const pressed = canvas.getAllByRole('button', { pressed: true });
		expect(pressed).toHaveLength(1);
		expect(pressed[0]!.textContent).toContain('1 field initialized');
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if causeTrail}
					<History
						documentRef={causeTrail.ref}
						selected={controlledSelected}
						onSelect={(mut) => (controlledSelected = mut?.id)}
					/>
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="LinkedMutationBeyondFirstPage"
	play={async () => {
		const canvas = within(document.body);
		// The controlled selection names the OLDEST mutation; the walk fetches
		// older pages until the row appears and the detail pane resolves it.
		// The fixtures land asynchronously — wait for the state and the DOM
		// together.
		await waitFor(() => {
			expect(pagedTrail).not.toBeNull();
			expect(canvas.getByTitle(pagedTrail!.oldestId)).toBeVisible();
		});
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if pagedTrail}
					<History documentRef={pagedTrail.ref} selected={pagedTrail.oldestId} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="LinkedMutationMissing"
	play={async () => {
		const canvas = within(document.body);
		// A selection the loaded history cannot resolve shows the dedicated
		// message instead of the generic select hint.
		await waitFor(() => expect(canvas.getByText(/not in the loaded history/)).toBeVisible());
		await expect(canvas.queryByText('Select a mutation to inspect its changes.')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="height:80vh;min-height:560px;display:flex;padding:24px;background:var(--sunken)">
			<div style="width:760px;max-width:100%">
				{#if causeTrail}
					<History documentRef={causeTrail.ref} selected={MISSING_MUTATION_ID} />
				{:else}
					<div style="color:var(--text-2);font-size:13px;padding:24px">Loading…</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Story>

<style>
	.revert-banner {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 10px 14px;
		border: 1px solid var(--ok);
		background: var(--ok-weak);
		color: var(--ok);
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
	}

	.revert-banner code {
		font-family: var(--font-mono);
		font-size: 11.5px;
	}
</style>
