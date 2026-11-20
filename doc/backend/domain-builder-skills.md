# Domain Builder Skills

The domain-builder assistant ships a set of LLM skill files that teach how to author doctype definitions, views, and fixtures. This page is for the **coder agent**: it points the way to those skill files and to the fixture files they were distilled from, for future fixture work. The builder assistant itself does not know fixture names — design it to a draft domain in AGENTS.md and the skill bodies only.

## What they are

Plain `.md` files with YAML front-matter (`title`, `description`, `tags`) under `src/assistant/domain_builder/skills/`. The filename (minus `.md`) is the skill name passed to the `read_skill` tool. Loaded once at process start by `Facet::Assistant::DomainBuilder::Skills.load_all` (`src/assistant/domain_builder/skills.cr`). `Skills.names` feeds the `enabled_tools` list at conversation-creation time, so the skill list is auto-discovered — no registry to update.

The full inventory, loading rules, and tool table are documented in [`backend/assistant.md`](backend/assistant.md) → Domain Builder Assistant.

**Reach boundary.** The corpus serves the in-app builder assistant only, through its `read_skill` tool. No REST route, MCP tool, or export exposes these files to an external agent — the MCP `read_skill` mount serves the shared agent-tool corpus (`src/agent_tools/skills/`, front-matter-tagged per surface) and never this one (see [`backend/mcp.md`](backend/mcp.md) → Tool catalogue). An external agent that wants this authoring knowledge works from the REST docs: [`build-a-domain.md`](../ops/build-a-domain.md), [`doctype-system.md`](doctype-system.md), and [`draft-domains.md`](draft-domains.md).

## Skills relevant to view fixtures

| Skill | File | What it teaches |
|---|---|---|
| Layout authoring | `src/assistant/domain_builder/skills/dvt-layouts.md` | How to structure a document view template so it looks good — the `view`, `form`, `quickView`, `inline`, and `card` surface patterns plus the cross-cutting layout rules. No fixture names; a generic doctype drives the examples. |
| Node vocabulary | `src/assistant/domain_builder/skills/document-views.md` | `core.DocumentView` structure, the `kind` enum, the full template node vocabulary, and value resolution. |

## Fixture reference for the coder agent

When authoring or reviewing a Document View Template fixture, start from the reviewed reference set. This reference is valid for the coder agent only — the builder assistant never sees these names:

- `data/fixtures/crm.facet-domain/views/crm.Company/document_views/{card,form,view,quickView}.yml` — the validated, user-reviewed layout patterns.
- `data/fixtures/hr.facet-domain/views/hr.CandidateSkill/document_views/{inline,card,form,view,quickView}.yml` — a child doctype (skill) surface set, including the `inline` row.
- `src/assistant/domain_builder/skills/dvt-layouts.md` — the same rules, written generically so the builder can use them without fixture names.
- `data/fixtures/crm.facet-domain/doctypes/crm.Company.yml` — the matching doctype definition (field types, enum colors, `display_name`).

The definitive renderer rules and the full node contract live in `doc/frontend/workflow.md` → Document View Template.