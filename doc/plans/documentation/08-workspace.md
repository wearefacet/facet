# WP 08 — Use the workspace section (`/workspace/`)

Phase 2 · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/workspace/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.4. Audience: employees using the SPA (persona `user`). How-to pages: use the WP 00 skeleton with `## Steps`.

## Pages

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `workspace/sign-in-mfa.md` | Sign in, MFA, reset your password | `audience: [user]`, `features: [FE-01, IAM-01, IAM-03, IAM-04, IAM-05, IAM-10]` | `doc/backend/iam.md` |
| `workspace/dashboard.md` | The dashboard | `audience: [user]`, `features: [FE-02]` | `doc/frontend/platform.md` |
| `workspace/lists-filters-views.md` | Lists, filters and saved views (table, kanban, calendar) | `audience: [user]`, `features: [FE-03, DOC-02, DOM-21]` | `doc/backend/filter-set.md`, `doc/backend/collection-view.md`, `doc/frontend/filter-bar.md`, `doc/frontend/kanban.md`, `doc/frontend/calendar.md` |
| `workspace/viewing-editing-document.md` | Viewing and editing a document | `audience: [user]`, `features: [FE-04, FE-05, DOC-13]` | `doc/frontend/document-view.md`, `doc/backend/document.md` |
| `workspace/comments-attachments.md` | Comments and attachments | `audience: [user]`, `features: [DOM-06, FE-04]` | `doc/backend/sidecar.md`, `doc/frontend/sidecar-panel.md`, `doc/frontend/markdown-editor.md` |
| `workspace/history-undo.md` | History and undo (rollback) | `audience: [user]`, `features: [FE-06, AUD-02, AUD-04]` | `doc/backend/audit.md`, `doc/frontend/audit.md` |
| `workspace/search-command-palette.md` | Search and the command palette | `audience: [user]`, `features: [FE-07, DOC-06]` | `doc/backend/search.md`, `doc/frontend/command-palette.md` |
| `workspace/keyboard-shortcuts.md` | Keyboard shortcuts | `audience: [user]`, `features: [FE-08]` | `doc/frontend/shortcuts.md` — this page is mostly the shortcut table |
| `workspace/notifications.md` | Notifications | `audience: [user]`, `features: [FE-09, AUT-06]` | `doc/backend/notifications.md`, `doc/frontend/notifications.md` |
| `workspace/import-export.md` | Import and export data | `audience: [user, author]`, `features: [FE-18, DOC-11]` | `doc/backend/import-export.md` |
| `workspace/assistant.md` | Using the assistant | `audience: [user]`, `features: [FE-22, AI-01]` | `doc/backend/workspace-assistant.md`, `doc/frontend/chat.md` |
| `workspace/settings-sessions-api-keys.md` | Your settings, sessions and API keys | `audience: [user]`, `features: [FE-17, PLT-17, IAM-09, IAM-11]` | `doc/backend/settings.md`, `doc/backend/iam.md`, `doc/frontend/settings.md` |

`workspace/index.md` (from WP 01): finish with the page list as links.

## Writing notes

- Write against the UI as it is. Run the frontend (`./scripts/dev`) and check each screen while you write. Where the WP 00 rule "document what exists" bites (a control is missing), report it — do not invent UI.
- Screenshots: optional. Prefer one labeled mermaid or table over many images. If you add images, put them in `site-docs/src/assets/` and keep names stable.
- The assistant page states plainly what the assistant can see and do under the caller's rights — link to `/concepts/ai-under-callers-rights/`.

## Definition of done

- [ ] Twelve pages + finished index, front-matter per WP 00.
- [ ] Every UI step checked against a running instance.
- [ ] `cd site-docs && npm run build` passes.
