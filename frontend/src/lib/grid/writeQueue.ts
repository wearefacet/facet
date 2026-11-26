// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The grid's write queue — one PATCH per row, a concurrency cap, and the
 * session undo/redo history.
 *
 * A cell edit becomes `push(rowId, diff)`. Ops that target the same row
 * merge while they wait: at most one PATCH is in flight per row, and the
 * ops that arrive during it collapse into the queued follow-up. At most
 * `concurrency` (default 4) row PATCHes run at once — a multi-cell burst
 * never floods the backend.
 *
 * The queue owns the undo/redo history, one unit per user action. A push
 * that carries an `action` token (and a `before` diff) records
 * `{ rowId, before, after, action }` once its PATCH resolves;
 * `popUndoAction` hands every entry of the newest action back for the grid
 * to invert — a multi-row paste undoes in one press, whatever order the
 * PATCHes resolved in. Undo and redo writes carry no token, so they never
 * record themselves. An undone group moves to the redo stack
 * (`pushRedo`); a redo pops it and `restoreUndo` puts it back on the undo
 * stack. A new action push clears the redo stack — the standard editor
 * rule.
 *
 * No DOM, no Svelte state — the Vitest `server` project covers the
 * scheduling and the history directly.
 */

/** The result of one row PATCH — the datasource's `DocumentResponse`. */
export type WriteResponse = unknown;

/** Options for one queued op. */
export interface WriteOptions {
	/**
	 * The value the row carried before this op — the undo entry's payload.
	 * Omit it on undo and redo writes.
	 */
	before?: Record<string, unknown>;
	/**
	 * The user-gesture token — one gesture (a cell commit, a flip, a whole
	 * pasted block) shares one token. The resolved op records an undo entry
	 * under it, and the redo stack drops: a new edit kills redo.
	 */
	action?: number;
}

/** One committed op, as the undo history holds it. `after` is the diff that
 *  was sent; `before` carries the pre-write values under the same keys. */
export interface UndoEntry {
	rowId: string;
	before: Record<string, unknown>;
	after: Record<string, unknown>;
	/** The gesture the op belongs to — the undo unit's identity. */
	action: number;
}

/** Issue one row PATCH. Rejects when the write fails (422, 403, network). */
export type RowUpdate = (rowId: string, diff: Record<string, unknown>) => Promise<WriteResponse>;

/** One row's waiting work: the merged PATCH body, the per-op diffs (the
 *  undo history replays per op, not per PATCH), and the waiting resolvers. */
interface RowJob {
	rowId: string;
	diff: Record<string, unknown>;
	perOp: { diff: Record<string, unknown>; before?: Record<string, unknown>; action?: number }[];
	resolvers: ((value: WriteResponse) => void)[];
	rejecters: ((reason: unknown) => void)[];
	running: boolean;
}

export function createWriteQueue(update: RowUpdate, concurrency = 4) {
	/** At most two jobs per row: the running one and the merged follow-up. */
	const jobs = new Map<string, RowJob[]>();
	/** LIFO stack of committed ops, newest last. */
	const undoStack: UndoEntry[] = [];
	/** LIFO stack of undone groups, newest last. */
	const redoStack: UndoEntry[][] = [];
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
						if (op.action != null && op.before) {
							undoStack.push({
								rowId: job.rowId,
								before: op.before,
								after: op.diff,
								action: op.action
							});
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
		if (options?.action != null) redoStack.length = 0;
		let queue = jobs.get(rowId);
		if (!queue) {
			queue = [];
			jobs.set(rowId, queue);
		}
		const last = queue[queue.length - 1];
		if (last && !last.running) {
			// Merge into the waiting job — one PATCH carries both ops.
			Object.assign(last.diff, diff);
			last.perOp.push({ diff, before: options?.before, action: options?.action });
			return new Promise((resolve, reject) => {
				last.resolvers.push(resolve);
				last.rejecters.push(reject);
			});
		}
		const job: RowJob = {
			rowId,
			diff: { ...diff },
			perOp: [{ diff, before: options?.before, action: options?.action }],
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

	/**
	 * Pop the newest action — every entry that shares the highest action id
	 * on the stack, or `null` when the stack is empty. The scan (not the
	 * stack top) keeps one gesture one unit even when its row PATCHes
	 * resolved out of order or interleaved with a later action's.
	 */
	function popUndoAction(): UndoEntry[] | null {
		if (undoStack.length === 0) return null;
		let newest = 0;
		for (const entry of undoStack) {
			if (entry.action > newest) newest = entry.action;
		}
		const group: UndoEntry[] = [];
		let write = 0;
		for (const entry of undoStack) {
			if (entry.action === newest) group.push(entry);
			else undoStack[write++] = entry;
		}
		undoStack.length = write;
		return group;
	}

	/** Move an undone group onto the redo stack — ⌘⇧Z's payload. */
	function pushRedo(group: UndoEntry[]): void {
		if (group.length === 0) return;
		redoStack.push(group);
	}

	/** Pop the newest undone group, or `null` when the redo stack is empty. */
	function popRedo(): UndoEntry[] | null {
		return redoStack.pop() ?? null;
	}

	/** Whether a redo group waits. */
	function canRedo(): boolean {
		return redoStack.length > 0;
	}

	/** Put a redone group back on the undo stack — ⌘Z must invert it again. */
	function restoreUndo(group: UndoEntry[]): void {
		for (const entry of group) undoStack.push(entry);
	}

	/** Drop every waiting job and clear the history — a teardown helper. */
	function clear(): void {
		jobs.clear();
		undoStack.length = 0;
		redoStack.length = 0;
	}

	return { push, canUndo, popUndoAction, pushRedo, popRedo, canRedo, restoreUndo, clear };
}

export type WriteQueue = ReturnType<typeof createWriteQueue>;
