---
title: Is Facet right for you?
description: Check where Facet helps, where it does not, and whether it matches your business.
audience: [evaluator]
features: [PLT-12]
sidebar:
  order: 2
verified_at: 7a6cb462
---

Decide before you install. This page gives you the fits, the misfits, and the
business cases where Facet is the answer.

## Good fits

Facet works well when most of these hold:

| Fit | What it gives you |
| --- | --- |
| **The business side builds its own apps** | No waiting on a development queue. A business person can describe the app to Claude Code, Claude Opus, or another coding agent, and ship it in hours. |
| **You want agentic speed without losing control** | Facet gives the agent a governed surface: it acts under one role you pin, and the platform checks every call, whatever wrote the code. |
| **The records must outlive the apps** | A customer stays a customer, whatever tool edits it. |
| **People see different rows and fields** | An auditor may ask who changed what. |
| **You are a small or mid-sized organization and want to self-host** | The data stays in your PostgreSQL, on your machines. |

Facet replaces the classical stack under the app — the bespoke backend, the
auth plumbing, the audit scripts. It does not replace the app; it makes the app
small enough to throw away.

## On the business side, the answer is yes

Facet pays back best in these five situations:

| Situation | What it gives you |
| --- | --- |
| **Sovereignty of your data** | The data stays in your PostgreSQL, on your machines. Nothing leaves unless you send it. |
| **Auditability and accountability is mandatory** | Every write lands in an append-only event log, with who, when, and what. This covers regulated industries such as healthcare and food. |
| **Free code you can deploy or adapt** | You hold the code. Deploy it, fork it, or change it to fit your organization. |
| **Limited access to software developers** | Business people describe the app to a coding agent and ship it. The platform carries auth, rights, and audit, so the app stays small. |
| **A business needing custom-made domains and applications** | Describe the domain in a draft, and Facet gives you the records, lists, rights, and history for it. |

## Poor fits

Facet is opinionated on purpose: one model of domains, doctypes, roles, and
history, applied to every write. These workloads need a lower level of control.
Use custom-made, less opinionated software for them — a plain database and
hand-built services:

| Workload | Why it does not fit | Use instead |
| --- | --- | --- |
| **Heavy data load** | Every write is validated, logged, and projected. That costs time and storage per row. | A plain PostgreSQL schema, tuned for the load |
| **Statistics and analytics** | Lists and filters serve daily operations, not aggregate scans over very large row counts. | An analytics engine, fed by exports |
| **B2C products** | Facet serves the people of one organization. Accounts come from invites and SSO — there is no public self-service sign-up. | A custom-built consumer stack |
| **Multi-tenancy** | One deployment serves one organization. Facet has no walls between separate customer companies. | A purpose-built multi-tenant design |
| **Time-series entries** | High-frequency timestamped rows want append-only storage with retention pruning, not per-row history. | A time-series database |
| **A business-specific IT architecture** | Facet imposes its model as-is: domains, doctypes, roles, and the event log. It does not reshape around a house architecture. | Custom services around your own architecture |
| **Wanting a hosted service** | Facet is self-hosted software; you run the servers. | A hosted platform |

## Decide in one afternoon

Run the stack, click through it, and build one small domain of your own:

1. Run the stack:

   ```sh
   git clone https://github.com/wearefacet/facet.git
   cd facet
   cp docker/.env.example docker/.env   # fill in hostname, SMTP, secrets
   docker compose -f docker/compose.prod.yml up -d --build
   docker compose -f docker/compose.prod.yml exec backend facet seed:admin ops@your-company.tld
   ```

2. Sign in with the printed one-time password.
3. Click through the workspace: lists, filters, document history.
4. Build one small domain of your own — [Domains, drafts and domain editors](/build/domains-drafts-editors/).

If step 4 took an hour and most of the good fits hold for you, Facet fits.

## Related

- [What is Facet](/start/what-is-facet/) — the product in one page.
- [Security & governance overview](/start/security-governance/) — the enforcement details behind the promises.
- [Deploy to production](/operate/production/) — the full install runbook.
