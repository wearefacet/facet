// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

export type {
	AssistantSseEvent,
	AssistantUsage,
	AgentMessage,
	Conversation,
	CreateConversationInput,
	CreateDomainBuilderConversationInput,
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
} from './types.js';

export type { AssistantDriver } from './AssistantDriver.js';
export {
	HttpAssistantDriver,
	HttpAssistantError,
	buildListQuery,
	parseSseStream
} from './http-assistant-driver.js';
export {
	runCatchup,
	DEFAULT_CATCHUP_OPTIONS,
	type CatchupOptions,
	type CatchupOutcome
} from './catchup.js';
export { MockAssistantDriver, MOCK_WORKSPACE_ACCOUNT_ID } from './mock/MockAssistantDriver.js';
export {
	collapseContentChunks,
	defaultScripts,
	errorScript,
	logisticsScript,
	longRunningScript,
	wordChunks,
	reasoningChunks,
	workspaceScript,
	workspaceFixtureDocumentIds,
	workspaceFixtureNames
} from './mock/scripts.js';
export type { AssistantScript, ScriptedChunk, ScriptedOutcome } from './mock/scripts.js';
export {
	applyChunkToParts,
	appendTextPart,
	appendReasoningPart,
	type AggregateKind,
	type AgentPart,
	type DocumentRow,
	type ListRows,
	type ShowDocuments,
	type Stats,
	type ToolCallEntry,
	type ViewPreview,
	parseListRowsResult,
	parseStatsResult
} from './tool-call-helpers.js';
export { reconstructTurns, type UiTurn } from './reconstruct-turns.js';
export {
	UI_TOOL_NAMES,
	buildPreviewDocument,
	fakeFieldValue,
	isNavigateChunk,
	isWorkspaceNavigateChunk,
	parseGoToPage,
	parseNavigateTarget,
	parseShowDocuments,
	parseViewPreview,
	templateFieldKeys,
	type BuilderPage,
	type GoToPageArgs,
	type NavigateTargetArgs,
	type NavigateTargetKind,
	type ShowDocumentsArgs,
	type ViewPreviewSpec
} from './ui-tools.js';
