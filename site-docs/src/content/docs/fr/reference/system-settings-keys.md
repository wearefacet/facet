---
title: Clés de réglage système
description: Chaque clé de réglage système, avec son type et sa valeur par défaut.
audience: [operator, admin]
features: [PLT-02]
type: reference
sidebar:
  order: 14
verified_at: 008dd880
---

> Généré depuis `src/system_settings/spec.cr` et `data/seeds/core.SystemSettings/definition.yml` par `make gen-docs-system-settings`. Ne modifiez pas ce fichier à la main.

Cette page sert à trouver une clé de réglage système, son type et sa valeur par défaut.

Les réglages système sont la configuration de la plateforme à l’exécution. Un document, `core.SystemSettings` (id `settings`), porte toutes les clés.

- **Un champ non nul épingle la valeur.**
- **Un null explicite rend la clé au fichier de configuration.**

Le registre liste chaque clé, son type, et la valeur par défaut intégrée que sert le palier fichier.

Les valeurs par défaut sont calculées, pas stockées. Le générateur construit la configuration intégrée depuis un YAML minimal en mémoire et exécute le repli fichier de chaque entrée — le troisième palier du code. À l’exécution, une valeur épinglée dans le document prime sur la valeur par défaut.

Les clés secrètes n’apparaissent jamais dans une réponse d’API de lecture. Un opérateur les définit par le flux déposer-et-adopter ; la valeur se trouve dans le magasin de secrets, et son effacement rend la clé au fichier de configuration.

| Clé | Type | Défaut | Rôle |
|---|---|---|---|
| `artifact.grant_prune_days` | number | 7 | Days an expired ephemeral grant row stays before the prune deletes it — the window counts from the link's expiry, not its mint. |
| `artifact.grant_ttl_media_seconds` | number | 21600 | Seconds a signed link stays valid for audio and video, so seeking mid-playback does not hit an expired URL. |
| `artifact.grant_ttl_seconds` | number | 3600 | Seconds a signed download link stays valid for documents and images. |
| `artifact.prune_after_days` | number | 30 | Days an artifact stays protected after its last reference ends, before the prune run can delete it. |
| `artifact.storage.type` | string | "filesystem" | Shows the effective storage adapter; the adapter wires at boot from the config file and the write gate refuses a pin. |
| `assistant.api_endpoint` | string | "https://api.openai.com/v1" | OpenAI-compatible endpoint URL. |
| `assistant.api_key` | secret | — | Set through the stage/adopt flow; shows as set/not-set, never as a value. |
| `assistant.auto_execute_tools` | bool | true | When true, registered tools run without a confirmation round-trip. |
| `assistant.max_history` | number | — | Conversation turns kept in context. |
| `assistant.max_tokens` | number | — | Completion token cap. |
| `assistant.model` | string | "gpt-4o" | Model identifier (e.g. 'gpt-4o'). |
| `assistant.name` | string | "Assistant" | Display name shown on every assistant surface — the workspace window, the builder window, and the top-bar entry point. |
| `assistant.system_prompt` | text | — | Default persona prompt. |
| `assistant.temperature` | number | — | Sampling temperature, 0.0 to 2.0. |
| `iam.auth.mode` | string | "hybrid" | 'hybrid' allows password and federated login; 'oidc_only' removes the password path. |
| `iam.change_password_expiration` | number | 86400 | Seconds a credential link stays valid: the password-reset link, the invite link, and the first-credential change token share one window. |
| `iam.mfa.enforcement` | string | "preferred" | 'preferred' asks but never blocks; 'always' holds every un-enrolled login at the enrollment step. |
| `iam.mfa.type` | string | "totp" | 'totp' enables TOTP MFA; 'none' turns MFA off — no challenge, no enroll hold. |
| `iam.oidc.provision_roles` | stringlist | [] | Roles assigned to every JIT-provisioned account whose provider sets no default_role — e.g. an 'employee' role. |
| `localization.default_language` | string | "en" | Language code applied to accounts without their own language. |
| `localization.default_timezone` | string | "auto" | IANA timezone name (e.g. 'Europe/Paris') applied to accounts without their own timezone, or 'auto' to follow each account's browser — the built-in default. |
| `mail.adapter` | string | "dev" | 'dev' prints emails to stdout; 'smtp' delivers through the smtp sub-object. |
| `mail.from_address` | string | "no-reply@facet.local" | Envelope and header sender address. |
| `mail.from_name` | string | "Facet" | Display name on the From header. |
| `mail.smtp.host` | string | "localhost" | SMTP server hostname. |
| `mail.smtp.password` | secret | — | Set through the stage/adopt flow; shows as set/not-set, never as a value. |
| `mail.smtp.port` | number | 587 | SMTP server port (1-65535). |
| `mail.smtp.use_tls` | bool | true | Upgrade the connection with STARTTLS after connecting. |
| `mail.smtp.username` | string | — | SMTP auth username. |
| `mutations.retention_days` | number | 180 | Days of edit history kept per document; older entries fold into one snapshot, and rollback past the window answers 404. |
| `tombstone.content_retention_days` | number | 30 | Days a deleted document keeps its content before the prune clears it. |

## Voir aussi

- [/fr/admin/configure/system-settings/](/fr/admin/configure/system-settings/)