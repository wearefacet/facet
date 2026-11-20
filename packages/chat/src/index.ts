// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Public surface of @facetapp/chat. Importing the package registers both
// custom elements (`<facet-assistant>` inline, `<facet-assistant-window>`
// floating) as a side effect and exports the `FacetAssistant` facade, the
// element classes, the driver layer, and the scripted mock.

// ── Custom elements ──────────────────────────────────────────────────────

export { FacetAssistantElement } from './element/facet-assistant.svelte.js';
export { FacetAssistantWindowElement } from './element/facet-assistant-window.svelte.js';
export type { AssistantDriver } from './driver/AssistantDriver.js';

export type {
	AgentMessage,
	AssistantSseEvent,
	AssistantUsage,
	Conversation,
	CreateAppConversationInput,
	CreateConversationInput,
	CreateDomainBuilderConversationInput,
	CreateWorkspaceConversationInput,
	ListConversationsParams,
	ListConversationsResult,
	RecordTurnInput,
	StreamAskInput,
	StreamChunk,
	StreamChunkKind,
	StreamTurnResult,
	ToolCallRef,
	ToolCallStatus,
	Turn,
	TurnSummary,
	Usage
} from './driver/types.js';

// ── Facade ─────────────────────────────────────────────────────────────────

export { FacetAssistant, type FacetAssistantConfig } from './facade.js';

// ── Real driver ──────────────────────────────────────────────────────────

export {
	HttpAssistantDriver,
	appConversationFilters,
	buildListQuery,
	parseSseStream
} from './driver/http-assistant-driver.js';
export { HttpAssistantError, readErrorMessage } from './driver/errors.js';

// ── Catch-up poll ────────────────────────────────────────────────────────

export {
	DEFAULT_CATCHUP_OPTIONS,
	runCatchup,
	type CatchupOptions,
	type CatchupOutcome,
	type LatestTurnProvider,
	type Sleep
} from './driver/catchup.js';

// ── Mock driver ──────────────────────────────────────────────────────────

export {
	createMockAssistant,
	MOCK_APP_ID,
	MOCK_WORKSPACE_ACCOUNT_ID,
	MockAssistantDriver
} from './driver/mock/MockAssistantDriver.js';
export {
	defaultScripts,
	errorScript,
	logisticsScript,
	longRunningScript,
	navigateScript,
	previewCollectionScript,
	previewDocumentScript,
	reasoningChunks,
	wordChunks,
	workspaceFixtureDocumentIds,
	workspaceFixtureNames,
	workspaceScript,
	type AssistantScript,
	type ScriptedChunk,
	type ScriptedOutcome
} from './driver/mock/scripts.js';
