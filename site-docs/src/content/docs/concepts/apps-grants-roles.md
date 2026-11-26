---
title: "Apps: grants ∩ roles"
description: Show how an app acts with the intersection of its grant and the elected role of the user.
audience: [developer, admin]
features: [RBC-08]
sidebar:
  order: 8
verified_at: 7a6cb462
---

An app that signs a user in never acts with that user's full rights. The app
acts with the intersection of the grant and the elected role. Read this page
to see what each side contributes.

## Explanation

<!-- d2
signin: "User signs in to the app" {class: external}
consent: "Consent screen is always shown"
role: "User elects one role"
grant: "App grant stored on the app document" {class: store}
scope: "Intersection of grant and elected role"
enforcers: "Enforcers apply the effective scope"

signin -> consent
consent -> role
role -> scope
grant -> scope
scope -> enforcers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/31157b28-light.svg" alt="User signs in to the app" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/31157b28-dark.svg" alt="User signs in to the app" loading="lazy" />
</div>

An app is a document in the `app.App` doctype. The registration carries a
grant. The grant is the maximum the app may ever do, for every user.

| Part of a grant entry | Holds |
| --- | --- |
| `target` | one concrete doctype path, such as `crm.Contact`; wildcard targets are refused |
| action `name` | `read`, `write`, `delete`, or a named action; `write` expands to `create` and `update` |
| action `required` | when `true`, a role that lacks the action cannot use the app |

At sign-in, the user elects one role on the consent screen. The consent
screen is always shown, even for a returning user. Facet then computes the
effective scope. The app may attempt only what sits in both sets.

**The grant caps even powerful users.** An admin role reaches every doctype.
Through the app, the same admin reaches only what the grant names. The grant
is a ceiling; it never widens a role.

**A grant change applies on the next call.** Facet re-resolves the grant on
every request, from the live app document. A grant change applies on the next
request, without a new token. No token caches the grant.

**Row scopes pass through.** If the elected role limits reads to `$mine`,
the app keeps that limit. The grant narrows which doctypes and actions a
request may attempt. It never relaxes a row filter.

**Backend apps.** A backend app has no user sign-in. It holds an API
(application programming interface) key and a service account with one pinned
role. Its reach is the same intersection: the grant and the pinned role.

**An app cannot widen its own grant.** The update hook on `app.App` rejects a
patch from an app-scoped caller. The patch cannot change `grants`, the
service role, or the service account. Operators keep full edit rights.

:::tip
When every route answers `401` with a valid key, read the server log. One
warning line names the role, the app, the key, and the missing actions. Then
widen the role, or narrow the grant.
:::

**The trade-off follows from the design.** The same app can work for one user
and fail for another. The grant is static, while the elected role varies per
user. When the app fails, check both sides: the grant on the app document,
and the permission lines of the elected role.

## Related

- [Apps](/build/apps/) — register an app, edit its grant, issue and rotate keys.
- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — how the elected role and the grant travel with each request.
- [Roles, levels and the authority guard](/admin/people/who-can-change-roles/) — the role model the elected role comes from.
- [Govern](/admin/) — edit the roles an app can elect.
- Internals on GitHub: [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
