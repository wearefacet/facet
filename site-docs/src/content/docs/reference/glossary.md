---
type: reference
title: Glossary
description: One short definition per term used across the Facet documentation, in alphabet order.
audience: [evaluator, user, author, admin, developer, operator]
features: []
sidebar:
  order: 1
verified_at: eee55a2
---

Facet keeps one meaning per word. The entries below define the product words
you meet on every page, then the words the technical pages use. Each entry
gives the plain definition, the other names you may meet, and the page that
explains the term in full.

## Product words

**Action** — A named operation a doctype declares, such as `approve`. A
caller runs it through a button or the API, and the run lands in history
like any other change. Also called: named action.
→ [Named actions](/build/model/behaviour/named-actions/)

**API key** — A secret token that authenticates a script or an app against
the API. Every account creates and revokes its own keys in the settings
page; apps carry keys of their own, which administrators manage in the
admin area.
→ [API keys](/admin/apps-access/api-keys/)

**App** — An external program registered in Facet that calls the API for
its users. Its reach is the overlap of the user's rights and the app's
grants.
→ [How apps work](/build/apps/how-apps-work/)

**Assistant** — The chat panel that works inside Facet. The workspace
assistant answers questions and edits documents; the domain-builder
assistant authors doctypes, views, and fixtures from a description.
→ [The assistant](/use/assistant/), [Build with the assistant](/build/model/in-app/build-with-assistant/)

**Backlink** — The record of another document that references this one.
The show page lists them under **Referenced by**.
→ [References and links](/build/model/relations/references-links/)

**Builder** — The in-app editor where authors create domains, doctypes,
and views without code files.
→ [Drafts and publishing](/build/model/in-app/drafts-and-publishing/)

**Bundle** — A folder of domain files (YAML, with Lua sidecars for
scripts) that defines a domain, ready for version control. Deploy it with
the CLI or edit it in the domain watcher.
→ [Domain bundles as files](/build/model/bundles/)

**Collection view** — A saved way to list one doctype's records: table,
kanban, calendar, or another surface, with its own filters and columns. A
view is personal or shared.
→ [Lists, boards and calendars](/build/model/views/lists-boards-calendars/)

**Document** — One record: a JSON body with a unique id, a current
version, and a full history of changes.
→ [How documents work](/discover/how-it-works/documents/)

**Doctype** — A typed record type inside a domain, such as `hr.Employee`.
Its definition declares the fields, the actions, and the scopes.
→ [Design doctypes](/build/model/data/design-doctypes/)

**Domain** — A namespace for one business area, such as `hr` or `sales`.
It groups doctypes and bounds rights and portability.
→ [Domains](/discover/how-it-works/domains/)

**Draft** — A throwaway draft domain, with an id that starts with `_`,
where you iterate on doctypes before you publish them to the live domain.
→ [Drafts and publishing](/build/model/in-app/drafts-and-publishing/)

**Field** — One typed slot in a doctype, such as `email` with the type
`string`. The type decides how the value is stored, checked, and shown.
→ [Field types](/build/model/data/field-types/)

**Field tag** — A label on a field that guards who sees it. A role must
hold the tag to read or write the field.
→ [Hide a field from some roles](/admin/people/hidden-fields/)

**Grant** — Explicit consent. An app grant says what an external app may
do; a domain grant lets one domain read named resources of another.
→ [App grants](/admin/apps-access/app-grants/), [Across domains](/build/model/relations/across-domains/)

**History** — The full list of changes of a document: who changed what,
when, and why. You can undo to any point.
→ [History and undo](/use/documents/history-undo/)

**Hook** — A Lua script Facet runs at a lifecycle point, such as before a
save. It can check, change, or refuse the change. Also called: event hook
(when it runs on the event bus).
→ [Scripts and guards](/build/model/behaviour/scripts-and-guards/), [Event hooks](/build/model/automation/event-hooks/)

**Permission** — What a role may do: read, create, update, delete, or run
an action, on a doctype path. A role holds a list of permission lines.
→ [Roles and permissions](/admin/people/roles-and-permissions/)

**Permission line** — The JSON form of one permission inside a role
document: `action`, `on`, and the optional `scope` and `except`.
→ [Permission line syntax](/reference/permission-syntax/)

**Publish** — The move of a checked draft domain to the live domain.
After the publish, users see the new doctypes.
→ [Drafts and publishing](/build/model/in-app/drafts-and-publishing/)

**Retention** — The rules that decide how long Facet keeps history,
tombstones, and job rows before it cleans them.
→ [Retention](/admin/history/retention/)

**Rollback** — The restore of a document to an earlier point of its
history. The workspace shows it as undo.
→ [History and undo](/use/documents/history-undo/)

**Role** — The unit of rights a person or app holds. A role carries
permission lines, visible field tags, and a level. Everyone acts under
one role at a time.
→ [Roles and permissions](/admin/people/roles-and-permissions/)

**Row scope** — A saved rule that decides which rows of a doctype a
permission reaches, such as "rows I own". Also called: named scope.
→ [Show each role only its own rows](/admin/people/row-scopes/)

**Service account** — A machine identity that signs in with an API key
instead of a password. A backend app uses one to act with a pinned role.
→ [Backend apps](/build/apps/connect/backend-apps/)

**Sidecar** — A doctype that attaches to any document through a reference
field, such as a comment or an attachment. Also called: comments and
attachments (UI).
→ [Comments and attachments](/build/model/relations/comments-attachments/)

**View template** — The saved template that defines how a document's show
page renders: the header, the tabs, the fields, and the relation tables.
→ [Document pages](/build/model/views/document-pages/)

**Webhook** — An outbound registration that delivers a signed event
message to your URL when a doctype changes.
→ [Outbound webhooks](/build/model/automation/webhooks/)

**Workspace** — The web application where people work with documents:
lists, boards, calendars, forms, and the assistant.
→ [The workspace](/use/)

## Engine words

These words describe how the engine works. Used in the technical pages and
in "How it works" sections; the everyday pages say it in plain words.

**At-most-once** — Event delivery that can drop an event in a failure but
never delivers it twice. The webhook reconcile job repairs a drop within
its window. *Used in the technical pages.*
→ [Events and delivery](/admin/under-the-hood/events-and-delivery/)

**Auth context** — The identity and rights bundle for one request: who
calls, the one elected role, and the app grant when an app calls. Also
called: `AuthContext` (code). *Used in the technical pages.*
→ [Auth contexts](/admin/under-the-hood/one-role-at-a-time/)

**Cause chain** — The record of why a change happened. Each change-log
row carries its direct cause; following the links shows the whole trail.
*Used in the technical pages.*
→ [Audit](/admin/history/audit/)

**Coalescing** — The fold of same-actor, same-channel document updates
inside a short window into one change-log row. *Used in the technical
pages.*
→ [The change log](/admin/under-the-hood/change-log/)

**Compaction** — The job that replaces change-log rows older than the
retention window with one summary row. *Used in the technical pages.*
→ [Retention](/admin/history/retention/)

**Consumer group** — A named reader position on the event stream. Each
group reads at its own speed and keeps its own place. *Used in the
technical pages.*
→ [Events and delivery](/admin/under-the-hood/events-and-delivery/)

**DPoP** — Token binding that proves each request carries the app's
private key. A stolen token alone cannot call the API. *Used in the
technical pages.*
→ [DPoP token binding](/build/apps/connect/dpop/)

**Elected role** — The one role a caller acts under for a request. Roles
never merge. *Used in the technical pages.*
→ [Auth contexts](/admin/under-the-hood/one-role-at-a-time/)

**Effective scope** — The rights a caller really has, resolved per
request: the role's scopes expand against the live definition, and an
app's grants cap the result. *Used in the technical pages.*
→ [App grants](/admin/apps-access/app-grants/)

**Enforcer** — The code that checks a rule on every request: it denies
the class of operation with `403` or narrows the rows. *Used in the
technical pages.*
→ [How access is enforced](/admin/under-the-hood/how-access-is-enforced/)

**ETag** — The version stamp of a document or a list, sent in response
headers. A client sends it back to update safely or to skip a download.
*Used in the technical pages.*
→ [REST API](/reference/rest-api/)

**Intersection (∩)** — The rule that an app can never do more than both
the user and the app are allowed. Written `grants ∩ roles`. *Used in the
technical pages.*
→ [Apps: grants ∩ roles](/build/apps/connect/what-an-app-can-do/)

**JSONB** — The PostgreSQL column type that stores a JSON document. Facet
stores every document body in one. *Used in the technical pages.*
→ [How documents work](/discover/how-it-works/documents/)

**Lazy migration** — The update of an old document to the current doctype
structure, the next time someone reads or writes it. *Used in the
technical pages.*
→ [Change a live domain](/build/model/change-a-live-domain/)

**Lease** — The time window one worker holds a background job, so other
workers leave it alone. *Used in the technical pages.*
→ [Jobs and cron](/admin/keep-running/jobs-cron/)

**Metadata gate** — The rule that serves a doctype or domain definition
to the callers that hold a grant on what the definition describes, and
hides the rest. It keeps the navigation of a scoped role working. *Used
in the technical pages.*
→ [How access is enforced](/admin/under-the-hood/how-access-is-enforced/)

**Mutation** — One row in the change log: who changed which document,
how, when, and why. Create, update, delete, and snapshot are mutations.
*Used in the technical pages.*
→ [The change log](/admin/under-the-hood/change-log/)

**Mutation log** — The append-only record of every change, in order.
History reads it; the current document state lives outside it. Also
called: history (UI). *Used in the technical pages.*
→ [The change log](/admin/under-the-hood/change-log/)

**PKCE** — The code-exchange protection in the OAuth 2.1 sign-in flow.
It stops an intercepted authorization code from being used. *Used in the
technical pages.*
→ [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/)

**Principal** — The identity that acts: a person, an app, or the system.
*Used in the technical pages.*
→ [How access is enforced](/admin/under-the-hood/how-access-is-enforced/)

**Projection** — The current version of a document: its content, label,
search text, and backlinks. Reads use projections; the log stores
history. *Used in the technical pages.*
→ [How documents work](/discover/how-it-works/documents/)

**Re-projection** — The rebuild of a document's current version after its
doctype definition changed. *Used in the technical pages.*
→ [Change a live domain](/build/model/change-a-live-domain/)

**Tombstone** — A deleted document Facet still remembers, for history and
restore. A tombstone is invisible to lists and search. *Used in the
technical pages.*
→ [Retention](/admin/history/retention/)

## Related

- [What is Facet](/discover/why-facet/)
- [Architecture at a glance](/discover/how-it-works/)
- [Security & governance overview](/discover/security/)
