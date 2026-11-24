// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The grid's write queue — one PATCH per row, a concurrency cap, and the
 * session undo stack.
 *
 * A cell edit becomes `push(rowId, diff)`. Ops that target the same row
 * merge while they wait: at most one PATCH is in flight per row, and the
 * ops that arrive during it collapse into the queued follow-up. At most
 * `concurrency` (default 4) row PATCHes run at once — a multi-cell burst
 * never floods the backend.
 *
 * The queue owns the undo stack. A push that carries a `before` diff
 * records `{ rowId, before, after }` once its PATCH resolves; `popUndo`
 * hands the last entry back for the grid to invert. An undo write pushes
 * with no `before`, so ⌘Z never re-records itself.
 *
 * No DOM, no Svelte state — the Vitest `server` project covers the
 * scheduling and the stack directly.
 */

/** The result of one row PATCH — the datasource's `DocumentResponse`. */
export type WriteResponse = unknown;

/** Options for one queued op. */
export interface WriteOptions {
	/**
	 * The value the row carried before this op. When given and the PATCH
	 * resolves, the queue records an undo entry — omit it on undo writes.
	 */
	before?: Record<string, unknown>;
}

/** One committed op, as the undo stack holds it. `after` is the diff that
 *  was sent; `before` carries the pre-write values under the same keys. */
export interface UndoEntry {
	rowId: string;
	before: Record<string, unknown>;
	after: Record<string, unknown>;
}

/** Issue one row PATCH. Rejects when the write fails (422, 403, network). */
export type RowUpdate = (rowId: string, diff: Record<string, unknown>) => Promise<WriteResponse>;

/** One row's waiting work: the merged PATCH body, the per-op diffs (the
 *  undo stack replays per op, not per PATCH), and the waiting resolvers. */
interface RowJob {
	rowId: string;
	diff: Record<string, unknown>;
	perOp: { diff: Record<string, unknown>; before?: Record<string, unknown> }[];
	resolvers: ((value: WriteResponse) => void)[];
	rejecters: ((reason: unknown) => void)[];
	running: boolean;
}

export function createWriteQueue(update: RowUpdate, concurrency = 4) {
	/** At most two jobs per row: the running one and the merged follow-up. */
	const jobs = new Map<string, RowJob[]>();
	/** LIFO stack of committed ops, newest last. */
	const undoStack: UndoEntry[] = [];
	let running = 0;

	function pump(): void {
		while (running < concurrency) {
			const job = takeNextJob();
			if (!job) return;
			running++;
			job.running = true;
			update(job.rowId, job.diff)
				.then((response) => {
					for (const op of job.perOp) {
						if (op.before) {
							undoStack.push({ rowId: job.rowId, before: op.before, after: op.diff });
						}
					}
					for (const resolve of job.resolvers) resolve(response);
				})
				.catch((reason) => {
					for (const reject of job.rejecters) reject(reason);
				})
				.finally(() => {
					running--;
					dropJob(job);
					pump();
				});
		}
	}

	function takeNextJob(): RowJob | null {
		for (const queue of jobs.values()) {
			const job = queue[0];
			if (job && !job.running) return job;
		}
		return null;
	}

	function dropJob(job: RowJob): void {
		const queue = jobs.get(job.rowId);
		if (!queue) return;
		const idx = queue.indexOf(job);
		if (idx >= 0) queue.splice(idx, 1);
		if (queue.length === 0) jobs.delete(job.rowId);
	}

	/**
	 * Queue one cell op. Resolves with the row's PATCH response — ops merged
	 * into the same PATCH resolve with the same response. Rejects when the
	 * PATCH fails; the op is then dropped (the caller owns the revert).
	 */
	function push(
		rowId: string,
		diff: Record<string, unknown>,
		options?: WriteOptions
	): Promise<WriteResponse> {
		let queue = jobs.get(rowId);
		if (!queue) {
			queue = [];
			jobs.set(rowId, queue);
		}
		const last = queue[queue.length - 1];
		if (last && !last.running) {
			// Merge into the waiting job — one PATCH carries both ops.
			Object.assign(last.diff, diff);
			last.perOp.push({ diff, before: options?.before });
			return new Promise((resolve, reject) => {
				last.resolvers.push(resolve);
				last.rejecters.push(reject);
			});
		}
		const job: RowJob = {
			rowId,
			diff: { ...diff },
			perOp: [{ diff, before: options?.before }],
			resolvers: [],
			rejecters: [],
			running: false
		};
		queue.push(job);
		const promise = new Promise<WriteResponse>((resolve, reject) => {
			job.resolvers.push(resolve);
			job.rejecters.push(reject);
		});
		pump();
		return promise;
	}

	/** Whether an undo entry waits. */
	function canUndo(): boolean {
		return undoStack.length > 0;
	}

	/** Pop the newest undo entry, or `null` when the stack is empty. */
	function popUndo(): UndoEntry | null {
		return undoStack.pop() ?? null;
	}

	/** Drop every waiting job and clear the stack — a teardown helper. */
	function clear(): void {
		jobs.clear();
		undoStack.length = 0;
	}

	return { push, canUndo, popUndo, clear };
}

export type WriteQueue = ReturnType<typeof createWriteQueue>;
