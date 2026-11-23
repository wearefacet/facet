<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import CommentSurface from './CommentSurface.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { PickerSources } from '$lib/referenceSearch.js';

	/**
	 * CommentSurface stories mount the threaded comment sidecar against a
	 * mock host. Author references resolve through the seeded `iam.Account`
	 * documents; a comment whose author ref cannot be resolved degrades to
	 * an unknown author. The shared composer submits `{ body }`, or adds
	 * `reply_to` while a reply is armed — the mock route stamps
	 * `target`, the backend forces `author` server-side and enforces the
	 * same-target thread rule.
	 */
	function makeDriver(seedComments: boolean, longBody: boolean = false): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Deal', {
			doctype: 'Deal',
			domain: 'crm',
			sidecar: true,
			sidecars: { comments: { doctype: 'core.Comment', column: 'target' } }
		});
		driver.registerDoctype('core', 'Comment', {
			doctype: 'Comment',
			domain: 'core',
			surface: 'comment',
			fields: {
				target: { key: 'target', type: 'reference', read_only: true, title: 'Target' },
				author: { key: 'author', type: 'reference', read_only: true, title: 'Author' },
				body: { key: 'body', type: 'longtext', title: 'Body' },
				reply_to: { key: 'reply_to', type: 'reference', title: 'Reply to' }
			}
		});
		driver.registerDoctype('iam', 'Account', {
			doctype: 'Account',
			domain: 'iam',
			fields: {
				name: { key: 'name', type: 'string', title: 'Name' }
			}
		});
		void driver.domain('crm').doctype('Deal', [{ id: 'crm.Deal.1', name: 'Platform License' }]);
		void driver.domain('iam').doctype('Account', [
			{ id: 'account_kim', name: 'Kim Alvein' },
			{ id: 'account_rex', name: 'Rex Mundi' }
		]);
		if (seedComments) {
			const rows = [
				{
					id: 'c1',
					body: 'First comment on the deal',
					target: 'crm.Deal.crm.Deal.1',
					author: 'iam.Account.account_kim'
				},
				{
					id: 'c2',
					body: 'Second comment with **markdown** emphasis',
					target: 'crm.Deal.1',
					author: 'iam.Account.account_rex'
				},
				// System-created comment: no author — degrades to unknown.
				{ id: 'c3', body: 'System-generated status note', target: 'crm.Deal.1' }
			];
			if (longBody) {
				rows.push({
					id: 'c4',
					body: LONG_BODY,
					target: 'crm.Deal.1',
					author: 'iam.Account.account_kim'
				});
			}
			void driver.domain('core').doctype('Comment', rows);
		}
		return driver;
	}

	/** Several wrapped paragraphs — tall enough to overflow the ~10-line
	 *  clamp and drive the Show more / Show less toggle. */
	const LONG_BODY = [
		'Checked against the filing and the enrichment output; two things need a second pass before we move this record forward.',
		'Revenue in the sheet is FY24, not TTM — the delta against the filing is material and changes the band we quoted.',
		'Headcount looks stale: three hires landed after the last refresh, so the per-seat cost estimate is low.',
		'Source is the 10-K, page 42, plus the enrichment job log from last night.',
		'Once the figures land we can hand it to finance for a second pass.',
		'After that pass the corrected band goes into the model, and the summary sheet picks up the revised per-seat figure.'
	].join('\n\n');

	const driver = makeDriver(true);
	const emptyDriver = makeDriver(false);
	// Fresh instance for the affordances story — SeededThread's play creates
	// a comment on `driver`, and module state is shared across stories in one
	// browser run (vite.config.ts → storybook project, isolate: false).
	const affordanceDriver = makeDriver(true);
	// Fresh instance for the clamp story — the expand toggle mutates local
	// state, so it must not share rows with the other seeded stories.
	const longDriver = makeDriver(true, true);
	// Fresh instance for the nested-thread story — the play replies into it
	// and toggles collapse state.
	const threadDriver = makeThreadedDriver();
	// Fresh instance for the fullscreen-send story — the play creates a
	// comment through it.
	const fullscreenDriver = makeDriver(false);
	// Fresh instance for the mention-picker story — the play creates a
	// comment through it.
	const mentionDriver = makeDriver(false);

	// ── Mention picker — synthetic sources ──────────────────────────────
	// The picker must not touch the network in a story (the same pattern
	// as the Markdown primitive stories): the bundle pins the People
	// candidates and the chip label resolver. Empty recents keep the
	// popup to the People group alone.
	const MENTION_ADA_ID = '01HZZZZZZZZZZZZZZZZZZZZZAA';
	const mentionSources: PickerSources = {
		searchAccounts: async (q) =>
			[
				{ id: MENTION_ADA_ID, name: 'Ada Lovelace' },
				{ id: '01HZZZZZZZZZZZZZZZZZZZZZAB', name: 'Bob Yeager' }
			].filter((a) => a.name.toLowerCase().includes(q.trim().toLowerCase())),
		recentDocuments: () => [],
		resolveLabel: async (domain, _doctype, id) =>
			domain === 'iam' && id === MENTION_ADA_ID
				? { status: 'ok', label: 'Ada Lovelace' }
				: { status: 'unknown' }
	};

	/** A five-level thread (the deepest reply flattens past the indent cap)
	 *  plus two replies whose parent was deleted — exercises the tree build,
	 *  the depth cap, the collapse toggle, and the `<deleted>` placeholder. */
	function makeThreadedDriver(): MockDataDriver {
		const drv = makeDriver(false);
		void drv.domain('core').doctype('Comment', [
			{
				id: 'c1',
				body: 'Top-level question about the renewal',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_kim'
			},
			{
				id: 'c2',
				body: 'Level one reply',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_rex',
				reply_to: 'core.Comment.c1'
			},
			{
				id: 'c3',
				body: 'Level two reply',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_kim',
				reply_to: 'core.Comment.c2'
			},
			{
				id: 'c4',
				body: 'Level three reply',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_rex',
				reply_to: 'core.Comment.c3'
			},
			{
				id: 'c5',
				body: 'Level four reply — past the indent cap',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_kim',
				reply_to: 'core.Comment.c4'
			},
			// Orphan: the parent comment was tombstoned, so the list never
			// returns it. A `<deleted>` placeholder stands in and both replies
			// nest under it.
			{
				id: 'c6',
				body: 'Reply whose parent was deleted',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_rex',
				reply_to: 'core.Comment.deleted_parent'
			},
			{
				id: 'c7',
				body: 'Second reply to the same deleted parent',
				target: 'crm.Deal.1',
				author: 'iam.Account.account_kim',
				reply_to: 'core.Comment.deleted_parent'
			}
		]);
		return drv;
	}

	const hostDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('crm.Deal') as Record<string, unknown>
	);
	const commentDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('core.Comment') as Record<string, unknown>
	);

	const hostDoc: DocumentResponse = {
		data: { name: 'Platform License' },
		meta: {
			id: 'crm.Deal.1',
			mid: 'crm.Deal.1',
			domain: 'crm',
			doc_type: 'Deal',
			version: 1,
			schema_version: 1,
			display_name: 'Platform License',
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString()
		}
	};

	/** Unrestricted — composer plus every affordance is visible. */
	const adminManifest = { '*.*': ['*'] };
	/** Composer only: host create grant, no flat `core.Comment` grants — the
	 *  per-comment edit/delete affordances stay hidden. */
	const composerOnlyManifest = { 'crm.Deal': ['create'] };
	/**
	 * `$mine`-shaped flat grants on the comment doctype (the seeded
	 * `comment_author` role): the host create grant enables the composer,
	 * the `core.Comment` grants enable edit/delete affordances.
	 */
	const mineManifest = { 'crm.Deal': ['create'], 'core.Comment': ['read', 'update', 'delete'] };

	const { Story } = defineMeta({
		title: 'Components/Features/Sidecar/CommentSurface',
		component: CommentSurface,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
</script>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('No comments yet.')).toBeVisible();
		// The composer is present with the host create grant.
		await expect(canvas.getByTestId('comment-composer')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={emptyDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="SeededThread"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// Thread renders oldest first with resolved author identities.
		await expect(canvas.getByText('Kim Alvein')).toBeVisible();
		await expect(canvas.getByText('Rex Mundi')).toBeVisible();
		// System-created comment (null author) still renders, as unknown author.
		await expect(canvas.getByText('System-generated status note')).toBeVisible();
		// No flat `core.Comment` grants → no per-comment affordances.
		await expect(canvas.queryByRole('button', { name: 'Edit comment' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Delete comment' })).toBeNull();

		// Typing into the composer and submitting appends a new row. Wait for
		// the debounced value sync first — the send reads `draft`, which lags
		// the visible text by the editor's emission debounce.
		const editor = canvasElement.querySelector<HTMLElement>(
			'[data-testid="comment-composer"] .ProseMirror'
		);
		if (!editor) throw new Error('Composer editor not mounted');
		const sendBtn = canvas.getByRole('button', { name: 'Comment' }) as HTMLButtonElement;
		const threadText = () => canvasElement.querySelector('.cs-thread')?.textContent ?? '';
		const waitUntil = async (cond: () => boolean): Promise<void> => {
			const start = Date.now();
			while (!cond()) {
				if (Date.now() - start > 3000) throw new Error('waitUntil timed out');
				await sleep(50);
			}
		};
		await userEvent.click(editor);
		await userEvent.type(editor, 'Typed by the play function');
		await waitUntil(() => !sendBtn.disabled);
		await userEvent.click(sendBtn);
		await waitUntil(() => threadText().includes('Typed by the play function'));

		// Enter sends from the composer too, like the assistant input.
		// Shift+Enter first: the editor keeps the newline, nothing sends.
		await userEvent.click(editor);
		await userEvent.type(editor, 'Sent with the keyboard shortcut');
		await waitUntil(() => !sendBtn.disabled);
		editor.dispatchEvent(
			new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true })
		);
		await sleep(300);
		expect(threadText()).not.toContain('Sent with the keyboard shortcut');
		editor.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
		await waitUntil(() => threadText().includes('Sent with the keyboard shortcut'));
		// The send cleared the composer for the next comment.
		await expect(sendBtn).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={composerOnlyManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface {driver} {hostDef} {hostDoc} segment="comments" sidecarDef={commentDef} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	A five-level reply thread plus an orphan. The play asserts the tree
	structure (data-depth), the indent cap with the "replying to" note,
	orphan hoisting, the collapse toggle, and a reply armed on the shared
	composer from the composer-only role (host create grant only).
-->

<Story
	name="NestedThread"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		const depthOf = (id: string) =>
			canvasElement.querySelector<HTMLElement>(`[data-comment-id="${id}"]`)?.dataset.depth;

		// Tree structure mirrors the reply chain.
		expect(depthOf('c1')).toBe('0');
		expect(depthOf('c2')).toBe('1');
		expect(depthOf('c3')).toBe('2');
		expect(depthOf('c4')).toBe('3');
		// Level four clamps to the cap and carries the "replying to" note.
		expect(depthOf('c5')).toBe('3');
		await expect(canvas.getByText('replying to Rex Mundi')).toBeVisible();
		// The tombstoned parent renders as a muted `<deleted>` placeholder at
		// the root; both of its live replies nest under it at depth 1.
		expect(depthOf('deleted:deleted_parent')).toBe('0');
		await expect(canvas.getByText('<deleted>')).toBeVisible();
		expect(depthOf('c6')).toBe('1');
		expect(depthOf('c7')).toBe('1');

		// Collapsing the placeholder hides its whole subtree.
		const phCollapse = canvasElement.querySelector<HTMLButtonElement>(
			'[data-comment-id="deleted:deleted_parent"] button[aria-label="Collapse replies"]'
		);
		if (!phCollapse) throw new Error('Placeholder collapse toggle not found');
		await userEvent.click(phCollapse);
		await sleep(100);
		await expect(canvas.queryByText('Reply whose parent was deleted')).toBeNull();
		await expect(canvas.queryByText('Second reply to the same deleted parent')).toBeNull();
		const phExpand = canvasElement.querySelector<HTMLButtonElement>(
			'[data-comment-id="deleted:deleted_parent"] button[aria-label="Expand replies"]'
		);
		if (!phExpand) throw new Error('Placeholder expand toggle not found');
		await userEvent.click(phExpand);
		await sleep(100);
		await expect(canvas.getByText('Reply whose parent was deleted')).toBeVisible();

		// Collapse c1's thread: its replies vanish, the toggle flips.
		const collapseBtn = canvasElement.querySelector<HTMLButtonElement>(
			'[data-comment-id="c1"] button[aria-label="Collapse replies"]'
		);
		if (!collapseBtn) throw new Error('Collapse toggle not found');
		await userEvent.click(collapseBtn);
		await sleep(100);
		await expect(canvas.queryByText('Level one reply')).toBeNull();
		const expandBtn = canvasElement.querySelector<HTMLButtonElement>(
			'[data-comment-id="c1"] button[aria-label="Expand replies"]'
		);
		if (!expandBtn) throw new Error('Expand toggle not found');
		await userEvent.click(expandBtn);
		await sleep(100);
		await expect(canvas.getByText('Level one reply')).toBeVisible();

		// Reply into c1 from a composer-only role: the affordance arms the
		// shared composer — chip above the input, highlight on the target.
		const replyBtn = canvasElement.querySelector<HTMLButtonElement>(
			'[data-comment-id="c1"] button[aria-label="Reply to comment"]'
		);
		if (!replyBtn) throw new Error('Reply affordance not found');
		await userEvent.click(replyBtn);
		await sleep(100);
		await expect(canvas.getByText('Replying to Kim Alvein')).toBeVisible();
		const targetCard = canvasElement.querySelector<HTMLElement>('[data-comment-id="c1"]');
		expect(targetCard?.classList.contains('cs-comment-replying')).toBe(true);
		// Cancelling clears both; re-arm for the actual reply.
		const cancelBtn = canvasElement.querySelector<HTMLButtonElement>(
			'[data-testid="comment-composer"] button[aria-label="Cancel reply"]'
		);
		if (!cancelBtn) throw new Error('Reply cancel button not found');
		await userEvent.click(cancelBtn);
		await sleep(100);
		await expect(canvas.queryByText('Replying to Kim Alvein')).toBeNull();
		expect(targetCard?.classList.contains('cs-comment-replying')).toBe(false);
		await userEvent.click(replyBtn);
		await sleep(100);
		const replyEditor = canvasElement.querySelector<HTMLElement>(
			'[data-testid="comment-composer"] .ProseMirror'
		);
		if (!replyEditor) throw new Error('Reply editor not mounted');
		await userEvent.click(replyEditor);
		await userEvent.type(replyEditor, 'Nested reply from the play function');
		// The Milkdown editor propagates its value asynchronously — wait until
		// the submit button enables before clicking.
		const submitBtn = canvas.getByRole('button', { name: 'Comment' }) as HTMLButtonElement;
		const waitUntil = async (cond: () => boolean, label: string): Promise<void> => {
			const start = Date.now();
			while (!cond()) {
				if (Date.now() - start > 3000) throw new Error(`waitUntil timed out: ${label}`);
				await sleep(50);
			}
		};
		await waitUntil(() => !submitBtn.disabled, 'submit-enabled');
		await userEvent.click(submitBtn);
		await waitUntil(
			() =>
				canvas
					.queryByText('Nested reply from the play function')
					?.closest('li')
					?.getAttribute('data-depth') === '1',
			'reply-at-depth-1'
		);
		const newLi = canvas.getByText('Nested reply from the play function').closest('li');
		expect(newLi?.getAttribute('data-depth')).toBe('1');
	}}
>
	{#snippet template()}
		<CanFixture manifest={composerOnlyManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={threadDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	The flat `comment_author` role shape: `create` on the host (implied
	nested-create grant) plus flat `update`/`delete` on `core.Comment` —
	edit and delete affordances become visible per comment.
-->

<Story
	name="MineAffordances"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		await expect(canvas.getAllByRole('button', { name: 'Edit comment' }).length).toBe(3);
		await expect(canvas.getAllByRole('button', { name: 'Delete comment' }).length).toBe(3);
		// The composer stays enabled with the host create grant.
		await expect(canvas.getByTestId('comment-composer')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={mineManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={affordanceDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="NoHostCreateGrant"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Without the host create grant the composer is locked with a hint.
		await expect(canvas.getByText('You cannot comment on this document.')).toBeVisible();
		await expect(canvas.queryByTestId('comment-composer')).toBeNull();
		// The thread still renders.
		await expect(canvas.getByText('Kim Alvein')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'core.Comment': ['read'] }}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface {driver} {hostDef} {hostDoc} segment="comments" sidecarDef={commentDef} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	Enter from the composer's fullscreen editor sends the comment and
	closes the overlay — a successful send lands back on the inline
	composer, never on an emptied fullscreen editor.
-->

<Story
	name="Fullscreen send closes overlay"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		const editor = canvasElement.querySelector<HTMLElement>(
			'[data-testid="comment-composer"] .ProseMirror'
		);
		if (!editor) throw new Error('Composer editor not mounted');
		const sendBtn = canvas.getByRole('button', { name: 'Comment' }) as HTMLButtonElement;
		const threadText = () => canvasElement.querySelector('.cs-thread')?.textContent ?? '';
		const waitUntil = async (cond: () => boolean, label: string): Promise<void> => {
			const start = Date.now();
			while (!cond()) {
				if (Date.now() - start > 3000) throw new Error(`waitUntil timed out: ${label}`);
				await sleep(50);
			}
		};

		// Type, then push the composer into the fullscreen overlay.
		await userEvent.click(editor);
		await userEvent.type(editor, 'Sent from the fullscreen editor');
		await waitUntil(() => !sendBtn.disabled, 'submit-enabled');
		await userEvent.click(canvas.getByRole('button', { name: 'Expand' }));
		await expect(canvas.getByRole('dialog')).toBeInTheDocument();

		// Enter sends and closes the overlay.
		editor.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
		await waitUntil(
			() => threadText().includes('Sent from the fullscreen editor'),
			'comment-added'
		);
		await sleep(100);
		await expect(canvas.queryByRole('dialog')).toBeNull();
		await expect(sendBtn).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={composerOnlyManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={fullscreenDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Enter picks the mention while the picker is open"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		const editor = canvasElement.querySelector<HTMLElement>(
			'[data-testid="comment-composer"] .ProseMirror'
		);
		if (!editor) throw new Error('Composer editor not mounted');
		const sendBtn = canvas.getByRole('button', { name: 'Comment' }) as HTMLButtonElement;
		const threadText = () => canvasElement.querySelector('.cs-thread')?.textContent ?? '';
		const waitUntil = async (cond: () => boolean, label: string): Promise<void> => {
			const start = Date.now();
			while (!cond()) {
				if (Date.now() - start > 3000) throw new Error(`waitUntil timed out: ${label}`);
				await sleep(50);
			}
		};

		// Typing the @ trigger opens the reference picker over the composer.
		await userEvent.click(editor);
		await userEvent.type(editor, 'Pinging @Ad');
		await waitFor(() => canvas.getByRole('button', { name: /Ada Lovelace/ }));

		// Enter with the popup open confirms the candidate — it must not
		// publish the comment. The capture-phase send listener defers to
		// the picker while its popup is inside the composer wrapper.
		editor.dispatchEvent(
			new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
		);
		await waitFor(() => {
			expect(canvasElement.querySelector('.md-ref-picker')).toBeNull();
		});
		// The picked mention chip landed in the draft; the thread is empty.
		await waitFor(() => {
			expect(canvasElement.querySelector('.md-mention-chip')).not.toBeNull();
		});
		expect(threadText()).not.toContain('Pinging');

		// Picker closed — Enter sends the comment again.
		await waitUntil(() => !sendBtn.disabled, 'draft-synced');
		editor.dispatchEvent(
			new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
		);
		await waitUntil(() => threadText().includes('Pinging'), 'comment-added');
		await expect(sendBtn).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={composerOnlyManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={mentionDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
					sources={mentionSources}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

// Kept last: the shared browser (vite.config.ts → storybook project, // isolate: false) makes play
// interactions leak across stories — earlier // stories in this file hit the same ordering
sensitivity // (see the retry // pattern in the Edit story).
<Story
	name="Long comment clamps"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// The long body clamps to the ~10-line max-height and offers the toggle;
		// the three short bodies get none. scrollHeight keeps the full content
		// height even while clipped — clientHeight is the capped box.
		await expect(canvas.getByRole('button', { name: 'Show more' })).toBeVisible();
		const clampedBody = canvas.getByTestId('comment-body-c4');
		await expect(clampedBody.clientHeight).toBeLessThanOrEqual(216);
		await expect(clampedBody.scrollHeight).toBeGreaterThan(216);
		await userEvent.click(canvas.getByRole('button', { name: 'Show more' }));
		await expect(canvas.getByRole('button', { name: 'Show less' })).toBeVisible();
		await expect(clampedBody.clientHeight).toBeGreaterThan(216);
		// The opened body sits on an inset surface strip, not the card colour.
		const openedBg = getComputedStyle(clampedBody).backgroundColor;
		expect(openedBg).not.toBe('rgba(0, 0, 0, 0)');
		await userEvent.click(canvas.getByRole('button', { name: 'Show less' }));
		await expect(canvas.getByRole('button', { name: 'Show more' })).toBeVisible();
		// Short bodies carry no toggle at all.
		expect(canvas.getAllByRole('button', { name: 'Show more' }).length).toBe(1);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<CommentSurface
					driver={longDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>
