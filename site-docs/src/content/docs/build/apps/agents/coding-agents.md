---
title: Build apps with a coding agent
description: Point a coding agent at the docs site, the .md twins, and the llms.txt index to build a Facet app.
type: how-to
audience: [developer]
features: [AI-06]
verified_at: eee55a2
sidebar:
  order: 0
---

A coding agent can build a Facet app from this site. Every page ships in a
form that agents consume, and the docs follow rules that keep agent output
honest. You point the agent at the right pages; the pages carry the rest.

> **For agents:** Fetch `https://docs.facet.example/llms.txt` first — it indexes the two text
> sets. One topic: fetch the page twin at `https://docs.facet.example/<path>.md` — for example
> `/build/apps/data/rest-api.md` — byte-for-byte markdown, front-matter kept. Many sections:
> `/llms-small.txt` (compact) or `/llms-full.txt` (every English page in one file). Code blocks on
> this site are complete and runnable — copy them; do not invent calls.

## When to use this

Come here when:

- You build a Facet app with a coding agent.
- The agent invents endpoints or parameters.
- You must keep the agent's context small.

For domain modelling with an agent — the domain file folder, the watcher,
and the check loop — see
[Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/).
This page covers the app half: client code, credentials, and HTTP calls.

## Before you start

The build serves every page twice: rendered, and as raw markdown. The
machine-readable set:

| Address | Content |
| --- | --- |
| `/llms.txt` | The index of the other two files |
| `/llms-small.txt` | The abridged documentation — most pages, less detail |
| `/llms-full.txt` | The full text of every English page in one file |
| `/<path>.md` | One page as raw markdown — for example `/build/apps/data/rest-api.md` |

The `.md` twin is byte-for-byte: the front-matter (`audience`, `features`,
`verified_at`) stays, and a diagram stays an HTML comment holding its D2
source, next to the rendered image. The **Copy as markdown** button on each
page fetches the same twin. The examples below use `https://docs.facet.example`,
the placeholder in the repo config; use your deployment's docs address.

## Steps

### 1. Point the agent at the index

Fetch `/llms.txt` first. It is one small fetch, and it lists the two text
sets.

### 2. Pick the text set

Give the agent `/llms-small.txt` for a cheap scan. Give it `/llms-full.txt`
when the task spans many sections.

### 3. Fetch the page twin for one topic

For a single task, fetch the twin of the page that teaches it, and put the
text into the agent's context. The Example below carries the commands.

### 4. Ask for the change

Ask the agent to copy the complete code blocks the pages carry, instead of
inventing calls. When a call fails, send the agent back to the page twin.

## Explanation

### Why agents do well on this site

The docs follow writing rules that keep agent output honest:

- Every code block is complete and runnable. There are no `...` elisions,
  so the agent can paste a block verbatim.
- Every `/build/apps/` page opens with a **For agents** box: endpoints,
  keys, and the minimal call sequence in plain text.
- Tables carry the reference data: filters, errors, caps.
- Each page teaches one task. A targeted fetch beats a broad one.

### Prompting tips

- Give the base URLs — docs site and Facet instance — plus the app slug and
  the credential channel, before the task.
- When a call fails, tell the agent to re-read the page twin. Do not let it
  guess parameters.
- When the context is tight, fetch the page for the doctype or route, not
  the full text set.

### Where each half lives

An agent build has two halves, and the docs split them the same way:

| Half | The agent edits | Read |
| --- | --- | --- |
| The app — client code, auth, hosting | Your repository | The `/build/apps/` pages |
| The domain — doctypes, scopes, actions | `*.facet-domain/` files | [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/) |

The in-app assistant's own skill corpus teaches doctype and view authoring.
That corpus serves the in-app builder assistant only: no REST route, MCP
tool, or export exposes it to an external agent. An external agent authors
domains from the domain-file docs instead.

## Example

A complete fetch session:

```sh
# One small fetch: the index of the text sets.
curl -sL https://docs.facet.example/llms.txt

# One topic: the raw markdown twin of a page.
curl -sL https://docs.facet.example/build/apps/data/rest-api.md
```

The same pull from TypeScript. It feeds the page text to the agent's
context:

```ts
async function loadFacetPage(path: string): Promise<string> {
	const response = await fetch(`https://docs.facet.example${path}`);
	if (!response.ok) {
		throw new Error(`No page twin at ${path}: HTTP ${response.status}`);
	}
	return response.text();
}

const page = await loadFacetPage('/build/apps/data/rest-api.md');
// Hand `page` to the agent as context for the task.
```

## Troubleshooting

**The agent invents an endpoint.**

The page is not in its context. Fetch the twin into its context, then
repeat the request.

**The agent writes elided code.**

The site's blocks are complete. Ask the agent to copy the block, not to
sketch it.

**A `.md` twin answers `404`.**

French fallback routes have no twin. Fetch the English page.

**The agent's answers go stale after a doctype change.**

Re-fetch the pages that teach that doctype.

## Related

- [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/) — the domain half: files, watcher, check loop.
- [Use the REST API](/build/apps/data/rest-api/) — the page agents fetch most.
- [The TypeScript SDK](/build/apps/data/sdk/) — typed calls the agent can copy.
- [What agents can do](/build/apps/agents/agent-tools/) — the catalogue for runtime agents.
- [Reference](/reference/) — the machine-readable API reference.
