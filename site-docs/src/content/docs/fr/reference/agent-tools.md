---
title: Outils d’agent
description: Chaque outil d’agent, avec sa classe d’accès et ses paramètres.
audience: [developer, operator]
features: [AI-04]
type: reference
sidebar:
  order: 13
verified_at: 008dd880
---

> Généré depuis `src/agent_tools/` par `make gen-docs-agent-tools`. Ne modifiez pas ce fichier à la main.

Cette page sert à consulter un outil, sa classe d’accès et ses paramètres.

Facet expose un catalogue unique d’outils documentaires à toutes les surfaces d’agent. Le serveur de ressources MCP liste tout le catalogue sous `tools/list` ; les assistants embarqués montent le sous-ensemble dont ils ont besoin. Le registre contient 23 outils. La visibilité filtre la liste par rôle ; le contrôle s’exécute toujours à l’appel, exactement comme en REST.

La colonne Accès porte la balise `requires` de l’outil dans le registre. Un rôle voit un outil quand sa carte de permissions passe la classe :
- **`read`** — au moins une ligne de lecture.
- **`write`** — au moins une ligne create, update ou delete.
- **`action`** — une action nommée ou le joker `*`.
- **`none`** — toujours visible d’un principal connecté.

| Outil | Accès | Rôle | Paramètres |
|---|---|---|---|
| `aggregate_documents` | read | Aggregate documents of one doctype with the same filter grammar as list_documents. | aggregate (string, required)<br>doctype (string, required)<br>domain (string, required)<br>field (string, optional)<br>filters (object, optional)<br>parent_id (string, optional)<br>scope (string, optional) |
| `batch` | write | Apply an ordered list of writes atomically — all land or nothing does. | ops (array, required) |
| `call_action` | action | Execute a named action on one document. | action (string, required)<br>args (object, optional)<br>doc_id (string, required)<br>doctype (string, required)<br>domain (string, required) |
| `create_document` | write | Create one document of the given doctype. | content (object, required)<br>doctype (string, required)<br>domain (string, required)<br>parent_id (string, optional) |
| `create_sidecar` | write | Create one sidecar record attached to a host document — the host-scoped nested-sidecar create (REST: POST /Api/:domain/:doctype/:id/:segment), generic over every sidecar doctype (comments, attachments, ...). | content (object, required)<br>doc_id (string, required)<br>doctype (string, required)<br>domain (string, required)<br>segment (string, required) |
| `delete_document` | write | Soft-delete one document (tombstone, recoverable through audit replay). | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required) |
| `get_artifact` | read | Mint a short-lived signed download URL for one artifact. | artifact_id (string, required) |
| `get_backrefs` | read | Find the live documents that point at one document — the inverse of get_links. | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required) |
| `get_document` | read | Read one document by id. | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required)<br>expand (array, optional)<br>fields (array, optional) |
| `get_links` | read | Get the outbound links of one document — the urn:facet:… references this document points to (from its reference fields and inline longtext links). | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required) |
| `get_schema` | read | Get the full schema of one doctype: fields (types, required, constraints), named actions with their typed arguments, child doctypes, the parent doctype (member_of, on a child), sidecar segments (host-scoped record types attached through the nested routes — e.g. comments or attachments, via create_sidecar/list_sidecars), and named scopes. | doctype (string, required)<br>domain (string, required) |
| `list_artifact_refs` | read | List the live documents that currently reference one artifact — both 'file' field placements and inline urn:facet:artifact:<id> links in longtext. | artifact_id (string, required) |
| `list_doctypes` | read | List the document types of one domain. | domain (string, required) |
| `list_documents` | read | List documents of one doctype. | doctype (string, required)<br>domain (string, required)<br>expand (array, optional)<br>fields (array, optional)<br>filters (object, optional)<br>items (integer, optional)<br>page (integer, optional)<br>parent_id (string, optional)<br>scope (string, optional)<br>sort (array, optional) |
| `list_domains` | read | List the live domains (bounded contexts) available in Facet. | — |
| `list_mutations` | read | List the mutation history of one document, or — with no doc_id — the recent mutations of the whole workspace (domain/doctype narrow as filters; needs the wildcard read grant). | doc_id (string, optional)<br>doctype (string, optional)<br>domain (string, optional)<br>filters (object, optional)<br>items (integer, optional)<br>page (integer, optional)<br>sort (array, optional) |
| `list_sidecars` | read | List the sidecar records of one segment attached to a host document — the host-scoped nested-sidecar list (REST: GET /Api/:domain/:doctype/:id/:segment), generic over every sidecar doctype. | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required)<br>items (integer, optional)<br>page (integer, optional)<br>segment (string, required) |
| `ping` | none | Health probe. | — |
| `request_artifact_upload` | write | Get a one-time signed upload URL for a file artifact. | filename (string, required)<br>size_bytes (integer, optional) |
| `resolve_refs` | read | Resolve a batch of document URNs (urn:facet:domain:Doctype:id — the inline links of longtext fields, links entries, or reference values) to documents in one call. | fields (array, optional)<br>refs (array, required) |
| `search_documents` | read | Search every readable doctype at once — use it when you do not know where a document lives. | domain (string, optional)<br>items (integer, optional)<br>query (string, required) |
| `update_document` | write | Partially update one document. | doc_id (string, required)<br>doctype (string, required)<br>domain (string, required)<br>patch (object, required) |
| `whoami` | none | Read your own identity and access: the account you act as, the mounted role, its permission manifest (doctype -> actions and scope aliases), and the role's visible tags. | — |

Un outil ne fait pas partie du registre : `read_skill`, le chargeur de compétences. La surface MCP l’ajoute à `tools/list`, et l’assistant d’espace de travail monte le sien. Tous deux prennent un argument obligatoire, `name` (string). Ils servent le corpus de compétences partagé de `src/agent_tools/skills/`, filtré par le front-matter `surfaces` de chaque fichier de compétence.

## Voir aussi

- [/fr/apps/agent-tools/](/fr/apps/agent-tools/)
- [/fr/apps/mcp-agents/](/fr/apps/mcp-agents/)