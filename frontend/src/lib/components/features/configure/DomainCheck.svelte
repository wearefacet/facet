<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DomainCheckResult } from '$lib/datasource/domainCheck.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Latest aggregated domain check result.
		 *  - `undefined`: still loading.
		 *  - `DomainCheckResult` (possibly with empty issues): result ready.
		 *  - `error` (string): load failed — surface with a retry control. */
		check = undefined,
		/** Set to `true` while the parent is re-fetching the check. */
		loading = false,
		/** Error string surfaced on a failed fetch. */
		error = undefined,
		/** Called when the user clicks "Refresh". */
		onrefresh = () => {}
	}: {
		check?: DomainCheckResult | undefined;
		loading?: boolean;
		error?: string | undefined;
		onrefresh?: () => void;
	} = $props();

	const totalIssues = $derived(check?.issue_count ?? 0);
	const hasDoctypes = $derived((check?.doctypes.length ?? 0) > 0);
	const hasNotices = $derived(check?.doctypes.some((dt) => dt.notices.length > 0) ?? false);
</script>

<div class="check-pane">
	<div class="check-head">
		<div class="head-text">
			<h2 class="sec-title">{m.configure_domains_check_title()}</h2>
			<p class="sec-hint">
				{m.configure_domains_check_helper()}
			</p>
		</div>
		<button class="refresh-btn" class:loading onclick={onrefresh} disabled={loading}>
			{loading ? m.configure_domains_check_refreshing() : m.configure_domains_check_refresh()}
		</button>
	</div>

	{#if error}
		<div class="state err">
			<p class="state-msg">{error}</p>
			<button class="retry-btn" onclick={onrefresh}>{m.apps_try_again()}</button>
		</div>
	{:else if !check}
		<div class="state"><p class="state-msg">{m.configure_domains_check_loading()}</p></div>
	{:else if totalIssues === 0 && !hasNotices}
		<div class="state ok">
			<p class="state-msg">{m.configure_domains_check_ok()}</p>
		</div>
	{:else}
		{#if check.domain_issues.length > 0}
			<section class="group">
				<h3 class="group-title">{m.configure_domains_check_domain_group()}</h3>
				<ul class="issue-list">
					{#each check.domain_issues as issue, i (`dom-${i}`)}
						<li class="issue">
							<span class="cat mono" data-cat={issue.category}>{issue.category}</span>
							<span class="msg">{issue.message}</span>
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		{#if hasDoctypes}
			<section class="group">
				<h3 class="group-title">{m.configure_domains_check_doctype_group()}</h3>
				{#each check.doctypes as dt (dt.doctype_id)}
					<div class="dt-section">
						<button class="dt-head" type="button">
							<span class="dt-id mono">{dt.doctype_id}</span>
							<span class="count" class:zero={dt.issue_count === 0}>
								{dt.issue_count === 1
									? m.configure_domains_issue_count_singular({ count: dt.issue_count })
									: m.configure_domains_issue_count_plural({ count: dt.issue_count })}
							</span>
						</button>
						{#if dt.issues.length > 0}
							<ul class="issue-list">
								{#each dt.issues as issue, i (`${dt.doctype_id}-${i}`)}
									<li class="issue">
										<span class="cat mono" data-cat={issue.category}>{issue.category}</span>
										<span class="msg">
											{#if issue.field}<span class="field mono">{issue.field}</span>{/if}
											{issue.message}
										</span>
									</li>
								{/each}
							</ul>
						{/if}
					</div>
				{/each}
			</section>
		{/if}

		{#if hasNotices}
			<section class="group">
				<h3 class="group-title">{m.configure_domains_check_notices_group()}</h3>
				<p class="group-hint">
					{m.configure_domains_check_notices_helper()}
				</p>
				{#each check.doctypes as dt (dt.doctype_id)}
					{#if dt.notices.length > 0}
						<div class="dt-section">
							<div class="dt-head">
								<span class="dt-id mono">{dt.doctype_id}</span>
							</div>
							<ul class="issue-list">
								{#each dt.notices as notice, i (`${dt.doctype_id}-notice-${i}`)}
									<li class="issue">
										<span class="cat mono info" data-cat={notice.category}>{notice.category}</span>
										<span class="msg">{notice.message}</span>
									</li>
								{/each}
							</ul>
						</div>
					{/if}
				{/each}
			</section>
		{/if}
	{/if}
</div>

<style>
	.check-pane {
		display: flex;
		flex-direction: column;
		gap: 16px;
		padding: 4px 0;
	}

	.check-head {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		align-items: flex-start;
	}

	.head-text {
		flex: 1;
	}

	.sec-title {
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		margin: 0 0 6px;
	}

	.sec-hint {
		font-size: 12.5px;
		color: var(--text-3);
		line-height: 1.5;
		margin: 0;
	}

	.refresh-btn {
		flex: none;
		padding: 6px 12px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
	}

	.refresh-btn:hover:not(:disabled) {
		background: var(--sunken, var(--surface));
		border-color: var(--accent);
	}

	.refresh-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.state {
		padding: 24px;
		border: 1px dashed var(--border);
		border-radius: var(--r);
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
		text-align: center;
	}

	.state.ok {
		border-color: var(--ok);
		background: var(--ok-weak, rgba(34, 197, 94, 0.06));
	}

	.state.err {
		border-color: var(--danger);
		background: var(--danger-weak, rgba(220, 38, 38, 0.08));
	}

	.state-msg {
		font-size: 13px;
		color: var(--text-2, var(--text));
		margin: 0;
	}

	.state.ok .state-msg {
		color: var(--ok);
		font-weight: 600;
	}

	.state.err .state-msg {
		color: var(--danger);
	}

	.retry-btn {
		padding: 5px 12px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		font-size: 12px;
		cursor: pointer;
	}

	.group {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.group-title {
		font-size: 11px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--text-3);
		margin: 0;
		font-weight: 600;
	}

	.group-hint {
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.45;
		margin: 0;
	}

	.dt-section {
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}

	.dt-head {
		width: 100%;
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 9px 12px;
		background: var(--sunken, var(--surface-2, var(--surface)));
		border: none;
		cursor: default;
	}

	.dt-id {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
	}

	.count {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--warn);
	}

	.count.zero {
		color: var(--ok);
	}

	.issue-list {
		list-style: none;
		margin: 0;
		padding: 0;
	}

	.issue {
		display: grid;
		grid-template-columns: 110px 1fr;
		gap: 10px;
		padding: 8px 12px;
		border-top: 1px solid var(--border);
		font-size: 12.5px;
		line-height: 1.45;
		align-items: start;
	}

	.issue:first-child {
		border-top: none;
	}

	.issue .cat {
		font-size: 10.5px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		padding-top: 2px;
		color: var(--warn);
	}

	.issue .cat.info {
		color: var(--text-3);
	}

	.issue .msg {
		color: var(--text-2, var(--text));
	}

	.issue .field {
		margin-right: 4px;
		color: var(--text);
		font-weight: 600;
	}

	.mono {
		font-family: var(--font-mono);
	}
</style>
