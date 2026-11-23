# QA bug verification — 2026-11-23

Cross-check of the open `quality-assurance.Issue` tickets against the code
(0.2.0-beta working tree). One file per confirmed issue. All ten issues are
marked `verified` on Facet; the files below carry the evidence and the
corrections found during the check.

| Issue id | File | Verdict |
| --- | --- | --- |
| `06H0D786J860VXNN434DBGW51F` | [kanban-surface-not-full-page.md](kanban-surface-not-full-page.md) | Confirmed (cards are cut off, not compressed) |
| `06H0D4DCKGEGZQGF7NG0H7DEGF` | [assistant-minimized-bar-not-movable.md](assistant-minimized-bar-not-movable.md) | Confirmed (deliberate design; grab cursor misleads) |
| `06H0D3XJNGKJ698VPZZ3TAEQ3Z` | [collection-view-delete-missing.md](collection-view-delete-missing.md) | Confirmed for the UI; assistant part refuted (tool exists) |
| `06H0D3E854C2YA2TQRKCB3BV47` | [loginevent-actioner-system.md](loginevent-actioner-system.md) | Confirmed; two sub-claims corrected |
| `06H0D10S60DVC58H9DTSQSDBWJ` | [drafts-stale-after-publish.md](drafts-stale-after-publish.md) | Confirmed for publish; discard already invalidates |
| `06H0CZGE009B9S4RS6N784BH2G` | [dvt-template-stale.md](dvt-template-stale.md) | Confirmed; editor edits JSON, not YAML |
| `06H080QE8833XMJG1CV9W45HAE` | [table-array-fields-raw-json.md](table-array-fields-raw-json.md) | Confirmed |
| `06H080EMP488B4WX5WRGPBT77V` | [no-agent-domain-check.md](no-agent-domain-check.md) | Confirmed; collection views ARE checked (description gap) |
| `06H0800DJ8P20PGRM67H8KXJHA` | [preview-view-template-argument.md](preview-view-template-argument.md) | Phenomenon confirmed; no code drop found (upstream loss) |
| `06H07XD7MGA8YKX8SD4MM348ST` | [domain-grants-ui-gaps.md](domain-grants-ui-gaps.md) | Claim 3 confirmed; claims 1-2 partial |
