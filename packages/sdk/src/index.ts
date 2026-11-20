// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

export {
	ApiError,
	AuthError,
	DeletedError,
	NetworkError,
	NotFoundError,
	UsageError
} from './errors.js';
export type { ValidationError } from './errors.js';
export { staticKey } from './auth/provider.js';
export type { TokenProvider } from './auth/provider.js';
export { oauthBrowser } from './auth/oauth.js';
export type { OAuthBrowserOptions, OAuthProvider } from './auth/oauth.js';
export {
	browserFlowStore,
	browserTokenStorage,
	memoryFlowStore,
	memoryTokenStorage
} from './auth/storage.js';
export type { FlowStore, StoredTokens, TokenStorage } from './auth/storage.js';
export { cacheKey, memoryCache } from './cache.js';
export type { CacheEntry, CacheStore } from './cache.js';
export { requestJson } from './http.js';
export type { HttpMethod, RequestOptions } from './http.js';
export { serializeListParams } from './query.js';
export type { AggregateMode, ListParams } from './query.js';
export { createFacetClient } from './client.js';
export type {
	BackrefItem,
	BackrefsParams,
	BackrefsResponse,
	CollectionHandle,
	DomainHandle,
	DocumentMeta,
	DocumentRef,
	DocumentResponse,
	FacetClient,
	FacetClientOptions,
	FilesOptions,
	HistoryParams,
	HistoryResponse,
	ListItem,
	ListPage,
	ListResponse,
	MutationRecord,
	RollbackResponse
} from './client.js';
export { can, scopeAliases } from './me.js';
export type { AssistantCapability, CanAnswer, Me, MeAccount } from './me.js';
export { ARTIFACT_URN_PREFIX } from './artifacts.js';
export type {
	ArtifactGrant,
	ArtifactHandle,
	ArtifactMeta,
	ArtifactUploadResult,
	DownloadUrlOptions,
	PublishOptions,
	UploadOptions
} from './artifacts.js';
export type {

	FrameHandler,

	RealtimeHandle,

	RealtimeOptions,

	RealtimeSocket,

	RealtimeWebSocketConstructor,

	RefusalHandler,
	ReconnectHandler,

	WsFrame
} from './realtime.js';
