<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import ChatPanel from './ChatPanel.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import {
		defaultScripts,
		longRunningScript,
		MockAssistantDriver,
		MOCK_WORKSPACE_ACCOUNT_ID,
		workspaceFixtureDocumentIds,
		workspaceFixtureNames,
		type AssistantDriver,
		type AssistantScript,
		type AssistantSseEvent,
		type Conversation,
		type NavigateTargetArgs,
		type StreamAskInput
	} from '$lib/assistant/index.js';
	import type { TemplateNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ChatPanel',
		component: ChatPanel,
		tags: ['autodocs'],
		argTypes: {
			contextHint: { control: 'text' },
			placeholder: { control: 'text' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const WORKSPACE_CONTEXT = { kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID };

	/**
	 * Sends one message through the composer and waits for the streamed
	 * prose. Shared by the play functions below.
	 */
	async function sendAndAwaitReply(
		canvasElement: HTMLElement,
		message: string,
		expectText: RegExp
	): Promise<void> {
		const canvas = within(canvasElement);
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, message);
		await userEvent.click(canvas.getByRole('button', { name: 'Send message' }));

		// The user bubble renders immediately; the reply streams in.
		await expect(canvas.getByText(message)).toBeVisible();
		await waitFor(
			async () => {
				await expect(canvas.getByText(expectText)).toBeVisible();
			},
			{ timeout: 10_000 }
		);
	}

	/**
	 * Data driver for the workspace surfaces: the crm.Customer fixture
	 * documents the scripts show, their definition, and the `view` document
	 * template card mode renders. Seeded through `MockDataDriver`, exactly
	 * like the app seeds `DocumentDataDriver`.
	 */
	function makeDataDriver(): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Customer', {
			doctype: 'Customer',
			domain: 'crm',
			icon: 'building-2',
			fields: {
				name: { key: 'name', type: 'text', title: 'Name' },
				status: { key: 'status', type: 'enum', title: 'Status' }
			}
		});
		void driver.domain('crm').doctype(
			'Customer',
			workspaceFixtureNames.map((name) => ({
				id: workspaceFixtureDocumentIds[workspaceFixtureNames.indexOf(name)],
				name,
				status: 'active'
			}))
		);
		void driver
			.domain('core')
			.doctype('DocType', [{ id: 'crm.Customer', doctype: 'Customer', domain: 'crm' }]);
		void driver.domain('core').doctype('DocumentView', [
			{
				id: 'crm.Customer.document_view.card',
				kind: 'card',
				template: {
					type: 'col',
					children: [
						{
							type: 'section',
							label: 'Identity',
							children: [
								{ type: 'field', label: 'Name', value: '$name' },
								{ type: 'field', label: 'Status', value: '$status' }
							]
						}
					]
				} as TemplateNode
			}
		]);
		return driver;
	}

	// The replay driver persists one full scripted turn at module load, so
	// the Replay story selects a conversation whose history holds rows,
	// cards, stats, and a navigate call.
	const replayAssistant = new MockAssistantDriver();
	const replayData = makeDataDriver();
	const replayTargets: NavigateTargetArgs[] = [];
	const replayConversation: Conversation = await (async () => {
		const conv = await replayAssistant.createWorkspaceConversation();
		for await (const ev of replayAssistant.streamAsk(conv.id, {
			content: 'find my active customers'
		})) {
			if (ev.event === 'chunk' && ev.chunk.kind === 'tool_call' && ev.chunk.name === 'navigate') {
				// Mirror the panel's consumer — the arguments arrive forwarded.
				if (ev.chunk.status === 'ok' && ev.chunk.arguments) {
					replayTargets.push(JSON.parse(ev.chunk.arguments) as NavigateTargetArgs);
				}
			}
		}
		return conv;
	})();
</script>

<script lang="ts">
	// One mock backend per story driver — the same shape a real surface keeps.
	const workspaceDriver = new MockAssistantDriver();
	const workspaceData = makeDataDriver();

	/** Workspace `navigate` targets collected by the live story's handler. */
	const navTargets: NavigateTargetArgs[] = [];

	function collectNavTarget(target: NavigateTargetArgs): void {
		navTargets.push(target);
	}

	async function createWorkspaceConversation(): Promise<Conversation> {
		return workspaceDriver.createWorkspaceConversation();
	}

	// Builder-mode factory: binds each conversation to a draft domain, so the
	// mock's content-matched builder scripts (preview/logistics) serve it.
	async function createBuilderConversation(): Promise<Conversation> {
		return workspaceDriver.createDomainBuilderConversation({ draft_domain: '_mock_draft' });
	}

	// The cancel story pins the default scripts down to the long-running one
	// so the stop click always lands mid-turn.
	const cancelDriver = new MockAssistantDriver([longRunningScript]);

	async function createCancelConversation(): Promise<Conversation> {
		return cancelDriver.createWorkspaceConversation();
	}

	// The unconfigured story needs a rail-fetchable driver, but creation must
	// never fire — the panel guards it before reaching the factory.
	const unconfiguredDriver = new MockAssistantDriver();

	// The transport-break story mirrors a proxy reset mid-cancel: the stop
	// click posts the cancel and the SSE body dies before the `cancelled`
	// frame reaches the panel. The row stays `running` at that point — the
	// panel cannot know the server outcome yet, so the cancelled note must
	// come from the cancel intent, not from a server-truth rebuild.
	class TransportBreakDriver extends MockAssistantDriver {
		private breakArmed = false;

		cancel(turnToken: string): Promise<void> {
			this.breakArmed = true;
			return super.cancel(turnToken);
		}

		streamAsk(_conversationId: string, input: StreamAskInput): AsyncIterable<AssistantSseEvent> {
			const inner = super.streamAsk(_conversationId, input);
			return { [Symbol.asyncIterator]: () => this.breakOnCancel(inner) };
		}

		/** Re-yields the session events, but a `cancelled` frame after the
		 *  stop click never reaches the panel — the body throws first. */
		private async *breakOnCancel(
			inner: AsyncIterable<AssistantSseEvent>
		): AsyncGenerator<AssistantSseEvent> {
			for await (const ev of inner) {
				if (ev.event === 'cancelled' && this.breakArmed) {
					throw new TypeError('network error');
				}
				yield ev;
			}
		}
	}

	const breakDriver = new TransportBreakDriver([longRunningScript]);

	let breakConversationId = '';

	async function createBreakConversation(): Promise<Conversation> {
		const conv = await breakDriver.createWorkspaceConversation();
		breakConversationId = conv.id;
		return conv;
	}

	// The meter story pins a finite 30-day budget on the mock: the panel
	// fetches usage on mount and renders the meter above the composer. The
	// other stories keep the default (unlimited) driver, where it stays hidden.
	const meterAssistant = new MockAssistantDriver(defaultScripts, {
		usage: {
			total: 62000,
			budget: 100000,
			window_start: '2026-09-19T00:00:00.000Z',
			window_days: 30
		}
	});

	async function createMeterConversation(): Promise<Conversation> {
		return meterAssistant.createWorkspaceConversation();
	}

	// The capped story pins one script that ends at the agent's tool-call
	// iteration cap: the partial exchange (text, tool call, tool result,
	// text) stays on the row, and a reload replays it with the same error
	// line the live `error` event renders.
	const cappedScript: AssistantScript = {
		match: (content, _ctx) => /\bcap it\b/i.test(content),
		chunks: [
			{ kind: 'content', text: 'Listing the shipments first. ' },
			{ kind: 'tool_call', name: 'list_documents', status: 'running' },
			{ kind: 'tool_call', name: 'list_documents', status: 'ok', result: '3 rows' },
			{ kind: 'content', text: 'The loop hit its iteration cap before the answer.' }
		],
		outcome: { kind: 'capped' }
	};

	const cappedDriver = new MockAssistantDriver([cappedScript]);

	async function createCappedConversation(): Promise<Conversation> {
		return cappedDriver.createWorkspaceConversation();
	}

	// The active-on-load story reproduces a reload mid-turn: the mock backend
	// holds a conversation whose turn row is still `running`, with the cancel
	// token persisted on it. The play selects it, watches the busy state
	// (thinking indicator, disabled composer), switches to an idle
	// conversation to prove the rail stays navigable while the watch polls,
	// switches back, then settles the turn the way the real backend would
	// and expects the catch-up poll to rebuild the thread from server truth.
	const activeDriver = new MockAssistantDriver();
	const activeConversation: Conversation = activeDriver.createConversationSync({
		context: { ...WORKSPACE_CONTEXT }
	});
	activeDriver.seedRunningTurn(activeConversation.id, 'still there?', 'seeded-turn-token');

	// A second, idle conversation. An older `updated_at` pins it below the
	// generating row in the rail (the seed's touch stamps it with now()).
	const idleConversation: Conversation = activeDriver.createConversationSync({
		context: { ...WORKSPACE_CONTEXT }
	});
	activeDriver.seedRunningTurn(idleConversation.id, 'hello idle', 'idle-turn-token');
	activeDriver.settleRunningTurn(idleConversation.id, 'Idle reply.');
	idleConversation.updated_at = new Date(Date.now() - 60_000).toISOString();
</script>

<Story
	name="WorkspaceMode"
	play={async ({ canvasElement }) => {
		navTargets.length = 0;
		// The factory created a workspace conversation, the panel streamed the
		// fixture sequence, and the rail rebuilt around that conversation.
		await sendAndAwaitReply(canvasElement, 'find my active customers', /anything else/);
		const canvas = within(canvasElement);
		// Inline rows from `list_documents` — the fixture display names, not
		// raw ids. Two surfaces show each name: the rows part and the
		// `show_documents` card grid.
		await waitFor(
			async () => {
				await expect(canvas.getAllByText('Aurora Print Studio').length).toBeGreaterThanOrEqual(2);
			},
			{ timeout: 10_000 }
		);
		await expect(canvas.getAllByText('Northwind Supply Co').length).toBeGreaterThanOrEqual(2);
		await expect(canvas.getAllByText('Cascade Coffee Roasters').length).toBeGreaterThanOrEqual(2);
		// The card grid renders the seeded document-view template (one per
		// card, so the section heading appears three times).
		await waitFor(async () => {
			await expect(canvas.getAllByText('Identity').length).toBe(3);
		});
		// The stats card shows the money aggregate as per-currency tiles.
		await expect(canvas.getByText('$ 184,250.00')).toBeVisible();
		await expect(canvas.getByText('€ 42,980.00')).toBeVisible();
		// The navigate call keeps its tool bar; the live handler opened the
		// document target.
		await expect(canvas.getByText('navigate')).toBeVisible();
		await waitFor(async () => {
			await expect(navTargets).toEqual([
				{
					target: 'document',
					domain: 'crm',
					doctype: 'Customer',
					id: workspaceFixtureDocumentIds[0]
				}
			]);
		});
		// The default mock driver reports unlimited usage — the meter stays hidden.
		await expect(canvas.queryByText(/budget used/)).toBeNull();
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={workspaceDriver as AssistantDriver}
				context={{ ...WORKSPACE_CONTEXT }}
				createConversation={createWorkspaceConversation}
				navigateWorkspace={collectNavTarget}
				documentDriver={workspaceData}
				agentName="Kara"
				agentTag="workspace"
				placeholder="Ask about your documents…"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Replay"
	play={async ({ canvasElement }) => {
		// The module pre-ran one full turn on `replayAssistant` — its row is
		// already in the rail. Selecting it restores the parts from stored
		// turns; nothing navigates a second time.
		const canvas = within(canvasElement);
		const row = await waitFor(() => canvas.getAllByText('workspace conversation')[0]);
		await userEvent.click(row);
		// Same surfaces as the live turn — rebuilt from persisted messages.
		await waitFor(
			async () => {
				await expect(canvas.getAllByText('Aurora Print Studio').length).toBeGreaterThanOrEqual(2);
			},
			{ timeout: 10_000 }
		);
		await expect(canvas.getAllByText('Northwind Supply Co').length).toBeGreaterThanOrEqual(2);
		// The card grid renders the seeded document-view template (one per
		// card, so the section heading appears three times).
		await expect(canvas.getAllByText('Identity').length).toBe(3);
		await expect(canvas.getByText('$ 184,250.00')).toBeVisible();
		// Replay never re-navigates: the persisted navigate call renders its
		// bar, and no handler ran.
		await expect(canvas.getByText('navigate')).toBeVisible();
		expect(replayTargets.length).toBe(1);
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={replayAssistant as AssistantDriver}
				context={{ ...WORKSPACE_CONTEXT }}
				createConversation={() => Promise.resolve(replayConversation)}
				documentDriver={replayData}
				agentName="Kara"
				agentTag="workspace"
				placeholder="Ask about your documents…"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="BuilderMode"
	play={async ({ canvasElement }) => {
		// Builder parity: the panel accepts the floating window's prop set —
		// page-context chip, daymark, agent header. The default scripts answer
		// a "preview" message with a `preview_view` card. The page-context
		// wording stays neutral on purpose: the mock matches scripts on the
		// full message (prefix included), so a magic domain name would route
		// the turn to the wrong fixture script.
		await sendAndAwaitReply(canvasElement, 'show me a preview', /declared field types/i);
		const canvas = within(canvasElement);
		// The `preview_view` UI tool renders as a card, not a tool bar.
		await waitFor(
			async () => {
				await expect(canvas.getByText('Customer show view')).toBeVisible();
			},
			{ timeout: 8_000 }
		);
		// The page-context chip renders above the composer.
		await expect(canvas.getByText('supplier · doctypes')).toBeVisible();
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={workspaceDriver as AssistantDriver}
				context={{ kind: 'domain-builder', draft_domain: '_mock_draft' }}
				createConversation={createBuilderConversation}
				pageContext={() => '[Page context: Viewing: supplier · doctypes]'}
				contextHint="supplier · doctypes"
				daymark="supplier (draft)"
				agentName="Steve"
				agentTag="schema agent"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Cancel"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The `longRunningScript` streams slowly on a "cancel" message, so the
		// stop click lands mid-turn and the panel marks the turn cancelled.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'cancel please');
		await userEvent.click(canvas.getByRole('button', { name: 'Send message' }));
		await waitFor(async () => {
			await expect(canvas.getByRole('button', { name: 'Stop generating' })).toBeVisible();
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Stop generating' }));
		await waitFor(
			async () => {
				await expect(canvas.getByText('Cancelled.')).toBeInTheDocument();
			},
			{ timeout: 10_000 }
		);
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={cancelDriver as AssistantDriver}
				context={{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }}
				createConversation={createCancelConversation}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CancelTransportBreak"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const textarea = () => canvas.getByRole('textbox') as HTMLTextAreaElement;
		// The long-running script keeps the turn streaming until the stop
		// click arms the break.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'cancel please');
		await userEvent.click(canvas.getByRole('button', { name: 'Send message' }));
		await waitFor(async () => {
			await expect(canvas.getByRole('button', { name: 'Stop generating' })).toBeVisible();
		});
		// The stop posts the cancel; the driver then kills the SSE body
		// before the `cancelled` frame arrives. The row is still `running`,
		// so only the cancel-intent render can produce the note here.
		await userEvent.click(canvas.getByRole('button', { name: 'Stop generating' }));
		await waitFor(
			async () => {
				await expect(canvas.getByText('Cancelled.')).toBeInTheDocument();
			},
			{ timeout: 10_000 }
		);
		await expect(canvas.queryByText(/Error:/)).toBeNull();
		// Then the backend settles the row as cancelled (the cancel POST's
		// server-side effect). The catch-up watch rebuilds the thread from
		// server truth; the note survives it and the composer unlocks.
		breakDriver.settleRunningTurnAsCancelled(breakConversationId, 'Working on it…');
		await waitFor(
			async () => {
				await expect(textarea().disabled).toBe(false);
			},
			{ timeout: 10_000 }
		);
		await expect(canvas.getByText('Cancelled.')).toBeInTheDocument();
		await expect(canvas.queryByText(/Error:/)).toBeNull();
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={breakDriver as AssistantDriver}
				context={{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }}
				createConversation={createBreakConversation}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CappedTurn"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The capped script streams its partial exchange, then the mock emits
		// the normal `error` event with the cap message and completes the row
		// as `capped`. The tool call bar and the error line render live.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'cap it please');
		await userEvent.click(canvas.getByRole('button', { name: 'Send message' }));
		await waitFor(
			async () => {
				await expect(canvas.getByText('list_documents')).toBeVisible();
			},
			{ timeout: 10_000 }
		);
		// The markdown renderer turns the leading `> ` into a blockquote, so
		// the rendered line reads without it.
		await expect(
			canvas.getByText(/Error: Agent error: tool call iteration limit \(100\) exceeded/)
		).toBeVisible();

		// A capped row replays its persisted partial exchange on reload. The
		// fresh conversation sorts first (updated_at DESC), so the capped one
		// is the second row after the new-conversation click.
		await userEvent.click(canvas.getByRole('button', { name: '+ New' }));
		await waitFor(() => expect(canvas.getAllByText('workspace conversation').length).toBe(2));
		const rows = canvas.getAllByText('workspace conversation');
		await userEvent.click(rows[1]);

		// The rebuilt thread shows the same tool call and error line from the
		// persisted row — the replay path through turnsFromRows.
		await waitFor(
			async () => {
				await expect(canvas.getByText('list_documents')).toBeVisible();
			},
			{ timeout: 10_000 }
		);
		await expect(
			canvas.getByText(/Error: Agent error: tool call iteration limit \(100\) exceeded/)
		).toBeVisible();
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={cappedDriver as AssistantDriver}
				context={{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }}
				createConversation={createCappedConversation}
				agentName="Kara"
				agentTag="workspace"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="UsageMeter"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The pinned driver reports 62% of a finite 30-day budget: the meter
		// renders above the composer without blocking the chat.
		await waitFor(
			async () => {
				await expect(canvas.getByText('62% of the 30-day budget used')).toBeVisible();
			},
			{ timeout: 10_000 }
		);
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={meterAssistant as AssistantDriver}
				context={{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }}
				createConversation={createMeterConversation}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ActiveOnLoad"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const textarea = () => canvas.getByRole('textbox') as HTMLTextAreaElement;
		const rows = () => canvas.getAllByText('workspace conversation');

		// Two conversations in the rail: the generating one first (its turn
		// touched it last), the idle one second.
		await waitFor(() => expect(rows().length).toBe(2));

		// Select the conversation whose turn row is still `running` server-side
		// — the state a reload mid-turn produces.
		await userEvent.click(rows()[0]);

		// The reloaded thread renders the persisted user bubble plus a live
		// thinking indicator; the composer locks into its busy state.
		await waitFor(async () => {
			await expect(canvas.getByText('Thinking…')).toBeVisible();
		});
		await expect(canvas.getByText('still there?')).toBeVisible();
		await expect(textarea().disabled).toBe(true);
		await expect(canvas.getByRole('button', { name: 'Stop generating' })).toBeVisible();

		// The watch must not hold the panel hostage: switching to an idle
		// conversation works while the poll runs, releases the composer, and
		// switching back resumes the busy state.
		await userEvent.click(rows()[1]);
		await waitFor(async () => {
			await expect(canvas.getByText('Idle reply.')).toBeVisible();
		});
		await waitFor(async () => {
			await expect(textarea().disabled).toBe(false);
		});

		await userEvent.click(rows()[0]);
		await waitFor(async () => {
			await expect(canvas.getByText('Thinking…')).toBeVisible();
		});
		await expect(textarea().disabled).toBe(true);

		// The backend settles the turn (here: the test helper completing the
		// running row). The next poll rebuilds the thread from server truth
		// and the panel returns to its normal state.
		activeDriver.settleRunningTurn(activeConversation.id, 'Yes — the reply is ready.');
		await waitFor(
			async () => {
				await expect(canvas.getByText('Yes — the reply is ready.')).toBeVisible();
			},
			{ timeout: 10_000 }
		);
		await waitFor(async () => {
			await expect(textarea().disabled).toBe(false);
		});
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={activeDriver as AssistantDriver}
				context={{ ...WORKSPACE_CONTEXT }}
				createConversation={() => Promise.resolve(activeConversation)}
				agentName="Kara"
				agentTag="workspace"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Unconfigured"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// The empty hint carries the not-configured message, and the
		// new-conversation button renders disabled with the same explanation.
		await waitFor(async () => {
			await expect(
				canvas.getByText(
					'This project has no AI assistant configured. An administrator can add one in System settings.'
				)
			).toBeVisible();
		});
		const newButton = canvas.getByRole('button', { name: 'New conversation' });
		await expect(newButton).toBeDisabled();

		// The composer locks too — a send would have to create a conversation
		// first, and the unconfigured posture must not fire one.
		await expect((canvas.getByRole('textbox') as HTMLTextAreaElement).disabled).toBe(true);
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={unconfiguredDriver as AssistantDriver}
				context={{ ...WORKSPACE_CONTEXT }}
				createConversation={() => Promise.reject(new Error('must not be called'))}
				configured={false}
				agentName="Kara"
				agentTag="workspace"
			/>
		</div>
	{/snippet}
</Story>
