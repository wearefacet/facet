// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Plain-English UI copy for the chat package.
 *
 * The main application localises its assistant through paraglide; the
 * package replaces those imports with this module so no i18n toolchain
 * crosses the package boundary. v1 ships English only. The `language`
 * option on the elements is unrelated — it feeds the backend's
 * `## Language` prompt block, not this copy.
 *
 * Keys mirror the main application's message names where the copy is the
 * same, so a future localisation pass can diff against `messages/en.json`.
 */

// ── Window chrome ─────────────────────────────────────────────────────────

export function assistant_title(): string {
	return 'Assistant';
}

export function assistant_open_aria(): string {
	return 'Open assistant';
}

export function assistant_close_aria(): string {
	return 'Close assistant';
}

export function assistant_collapse(): string {
	return 'Collapse';
}

export function assistant_collapse_aria(): string {
	return 'Collapse assistant';
}

export function assistant_expand(): string {
	return 'Expand';
}

export function assistant_expand_aria(): string {
	return 'Expand assistant';
}

export function assistant_maximize(): string {
	return 'Maximize';
}

export function assistant_maximize_aria(): string {
	return 'Maximize assistant';
}

export function assistant_restore(): string {
	return 'Restore';
}

export function assistant_restore_aria(): string {
	return 'Restore assistant';
}

export function assistant_resize_aria(): string {
	return 'Resize assistant';
}

export function assistant_resize_width_aria(): string {
	return 'Resize assistant width';
}

export function assistant_resize_height_aria(): string {
	return 'Resize assistant height';
}

export function assistant_window_controls_aria(): string {
	return 'Assistant window controls';
}

export function assistant_render_error(): string {
	return 'Something went wrong in the assistant panel.';
}

export function assistant_render_retry(): string {
	return 'Retry';
}

// ── Conversation rail ─────────────────────────────────────────────────────

export function assistant_conversations_title(): string {
	return 'Conversations';
}

export function assistant_conversations_new(): string {
	return '+ New';
}

export function assistant_conversations_show(): string {
	return 'Show conversations';
}

export function assistant_conversations_hide(): string {
	return 'Hide conversations';
}

export function assistant_conversations_show_archived(): string {
	return 'Show archived conversations';
}

export function assistant_conversations_empty(): string {
	return 'No conversations yet.';
}

export function assistant_conversations_archived_empty(): string {
	return 'No archived conversations.';
}

export function assistant_conversations_archive(): string {
	return 'Archive conversation';
}

export function assistant_conversations_unarchive(): string {
	return 'Unarchive conversation';
}

export function assistant_conversations_loading_more(): string {
	return 'Loading more…';
}

export function assistant_conversations_end(): string {
	return 'No more conversations';
}

export function assistant_conversation_excerpt(params: { kind: string }): string {
	return `${params.kind} conversation`;
}

export function assistant_conversation_fallback(): string {
	return 'Conversation';
}

export function assistant_rail_resize_aria(): string {
	return 'Resize conversation list';
}

// ── Thread ────────────────────────────────────────────────────────────────

export function assistant_empty_hint(): string {
	return 'Pick a conversation on the left, or start a new one.';
}

export function assistant_thread_empty(): string {
	return 'Send a message to start this conversation.';
}

export function assistant_new_conversation(): string {
	return 'New conversation';
}

export function assistant_thinking(): string {
	return 'Thinking…';
}

export function assistant_thought_label(): string {
	return 'Thought';
}

export function assistant_copy_answer(): string {
	return 'Copy answer';
}

export function assistant_copy_thought(): string {
	return 'Copy thought';
}

export function assistant_tag_schema(): string {
	return 'schema agent';
}

export function assistant_documents_error(): string {
	return 'Documents could not be shown.';
}

export function assistant_part_unsupported(): string {
	return 'This content cannot be displayed here.';
}

// ── Tool calls ────────────────────────────────────────────────────────────

export function assistant_tool_running(): string {
	return 'running…';
}

export function assistant_tool_ok(): string {
	return 'ok';
}

export function assistant_tool_error(): string {
	return 'error';
}

// ── Composer ──────────────────────────────────────────────────────────────

export function assistant_input_placeholder(): string {
	return 'Type a message…';
}

export function assistant_input_thinking(): string {
	return 'Agent is thinking…';
}

export function assistant_send_title(): string {
	return 'Send (Ctrl+Enter)';
}

export function assistant_send_aria(): string {
	return 'Send message';
}

export function assistant_stop_title(): string {
	return 'Stop (Ctrl+Enter)';
}

export function assistant_stop_aria(): string {
	return 'Stop generating';
}

// ── Usage meter ───────────────────────────────────────────────────────────

export function assistant_usage_meter(params: { percent: number; days: number }): string {
	return `${params.percent}% of the ${params.days}-day budget used`;
}

// ── Error / streaming notices ─────────────────────────────────────────────

export function assistant_error_line(params: { message: string }): string {
	return `> Error: ${params.message}`;
}

export function assistant_turn_failed(): string {
	return 'The turn failed.';
}

export function assistant_cancelled_note(): string {
	return '> Cancelled.';
}

export function assistant_still_generating(): string {
	return '> Still generating. Reopen the chat to catch up.';
}

export function assistant_usage_limit_reached(): string {
	return 'You have used your full assistant token budget for this 30-day window. Ask an administrator to raise the budget, or wait for older usage to leave the window.';
}

export function assistant_turns_load_failed(params: { message: string }): string {
	return `Failed to load turns: ${params.message}`;
}

export function assistant_conversation_create_failed(params: { message: string }): string {
	return `Failed to create conversation: ${params.message}`;
}

export function assistant_dismiss(): string {
	return 'Dismiss';
}

// ── Empty states ──────────────────────────────────────────────────────────

export function assistant_access_denied_title(): string {
	return 'Assistant unavailable';
}

export function assistant_access_denied_body(): string {
	return 'The assistant is not enabled for this app, or your role does not include assistant access.';
}

// ── Registry-tool surfaces (data-only renderers) ──────────────────────────

export function assistant_rows_matches(params: { count: number }): string {
	return `${params.count} matches`;
}

export function assistant_stats_rows(params: { count: number }): string {
	return `${params.count} rows`;
}

// ── Mermaid ───────────────────────────────────────────────────────────────

export function assistant_mermaid_pending(): string {
	return 'mermaid…';
}

export function assistant_mermaid_rendering(): string {
	return 'rendering…';
}

export function assistant_mermaid_invalid(): string {
	return 'mermaid: invalid diagram';
}

// ── Copy ──────────────────────────────────────────────────────────────────

export function common_copy(): string {
	return 'Copy';
}

export function common_copied(): string {
	return 'Copied';
}

export function common_close(): string {
	return 'Close';
}

// ── Relative time ─────────────────────────────────────────────────────────

export function common_time_now(): string {
	return 'now';
}

export function common_time_just_now(): string {
	return 'just now';
}

export function common_time_in(params: { value: number; unit: string }): string {
	return `in ${params.value}${params.unit}`;
}

export function common_time_ago(params: { value: number; unit: string }): string {
	return `${params.value}${params.unit} ago`;
}
