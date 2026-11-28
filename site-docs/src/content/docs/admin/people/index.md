---
title: People and access
description: Give each person an account, the right role, and the limits that role carries — in nine steps.
type: overview
audience: [admin]
features: [IAM-06, RBC-01]
verified_at: eee55a2
sidebar:
  order: 0
---

A new salesperson starts on Monday at Brightwater Rentals. Ravi, the part-time
admin, gives her an account, the Sales role, and a rule that shows her only
her own clients. Everything he clicks lands in the history, so the next audit
question already has an answer.

That is the whole people story. Facet splits it into nine steps, and this
group follows them in order. Each step is one page, and each page builds on
the last.

## The story in order

| # | Page | What you do there |
| --- | --- | --- |
| 1 | [Manage accounts](/admin/people/accounts/) | Create the account, send the first password or invite link, keep the status right. |
| 2 | [Roles and permissions](/admin/people/roles-and-permissions/) | Write a role: permission lines, a level, field tags, and the channels it may use. |
| 3 | [Assign roles](/admin/people/assign-roles/) | Put roles on accounts, and learn why one role acts at a time. |
| 4 | [Show each role only its rows](/admin/people/row-scopes/) | Attach a row scope so Sales sees only its own clients. |
| 5 | [Hide a field from some roles](/admin/people/hidden-fields/) | Tag `purchase_price` as `finance` so the warehouse never sees it. |
| 6 | [Who can change roles](/admin/people/who-can-change-roles/) | The guard that stops an editor from promoting themselves to admin. |
| 7 | [Require MFA](/admin/people/mfa/) | Ask for a second factor at sign-in, and recover a lost authenticator. |
| 8 | [Single sign-on (OIDC)](/admin/people/sso/) | Sign people in through your identity provider, or only through it. |
| 9 | [Sessions and lockouts](/admin/people/sessions-lockouts/) | Tokens, session lists, and what happens after ten wrong passwords. |

Two more pages sit outside this group but answer people questions: apps and
their API keys. When a program — not a person — needs access, read
[Control what apps can reach](/admin/apps-access/app-grants/) and
[API keys](/admin/apps-access/api-keys/).

## A rule of thumb

Give a person the narrowest role that lets them work. A row scope narrows
*which* documents they reach. A field tag narrows *which columns* they see.
The two stack: Tom the salesperson sees five companies, and inside an item he
sees no purchase price. Start narrow, watch the person work, then widen.

## Related

- [Administer](/admin/) — the full admin section, one layer up.
- [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/) — the deep view of every check this group configures.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the same model for programs instead of people.
