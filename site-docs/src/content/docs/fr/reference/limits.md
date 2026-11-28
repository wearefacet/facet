---
type: reference
title: Limites
description: Chaque limite stricte de Facet avec sa valeur, sa clé de configuration et le code qui l’applique.
audience: [admin, operator]
features: []
sidebar:
  order: 21
verified_at: eee55a2
---

Un opérateur planifie la capacité ou examine un refus, et a besoin du plafond
exact et de son origine. Cette page liste chaque limite stricte que le moteur
applique, avec sa valeur, la clé de configuration ou la constante qui la
porte, et le chemin et la ligne du code source. Les valeurs affichées sont les
valeurs par défaut ; un fichier de configuration ou une épingle dans les
Paramètres système peut changer celles qui dépendent d’une clé.

## Téléversements, imports et fichiers

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Plafond de téléversement des artefacts fichiers | 52,428,800 octets (50 MiB) ; au-delà, réponse `413` | `artifact.max_upload_bytes` | `src/artifact/config.cr:59,92`, `src/artifact/uploader.cr:770` |
| Plafond de lignes d’un import de documents | 100,000 lignes | `import_export.max_import_rows` | `src/config.cr:196-199,687` |
| Réutilisation du plafond de téléversement par les imports | le même plafond de 50 MiB sur les corps d’import de domaine et d’import de documents | `artifact.max_upload_bytes` | `src/domain/portable/routes.cr:240`, `src/import_export/staging.cr:40-42` |
| Attente de mise en file d’un import | 30 s | `import_export.wait_timeout_s` | `src/config.cr:196-199` |
| Sondage de mise en file d’un import | 500 ms | `import_export.wait_poll_ms` | `src/config.cr:196-199` |
| TTL d’attribution des artefacts (documents/images) | 3,600 s | `artifact.grant_ttl_seconds` | `src/artifact/config.cr:56-62` |
| TTL d’attribution des artefacts (médias) | 21,600 s | `artifact.grant_ttl_media_seconds` | `src/artifact/config.cr:56-62` |
| TTL des URL de téléversement signées | 300 s | `artifact.upload_grant_ttl_seconds` | `src/artifact/config.cr:56-62` |

## Grammaire des listes et de la recherche

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Taille de page des listes | 100 par défaut, 1,000 au maximum | `MAX_ITEMS` | `src/http/list_request.cr:28-29,95` |
| Paramètre de liste inconnu | réponse `422` | — (admission stricte) | `src/http/list_request.cr:476` |
| Valeurs d’un filtre `__in` | 100 au maximum | `MAX_IN_VALUES` | `src/util/filter_set.cr:43`, `src/document/filter_compiler.cr:773` |
| Plafond des agrégats comptés | 1,000 | `COUNT_CAP` | `src/http/responders.cr:604` |
| Plafond des sous-listes d’artefacts (attributions, références) | 500 | `Artifact::Admin::SUB_LIST_CAP` | `src/artifact/admin.cr:84` |
| Résultats de recherche par doctype | 5 | `MAX_PER_DOCTYPE` | `src/search/query.cr:20` |
| Résultats de recherche au total | 25 | `MAX_TOTAL` | `src/search/query.cr:23` |
| Profondeur de composition de la recherche | 8 | `MAX_DEPTH` | `src/search/query.cr:27` |
| Longueur de `display_name` | 255 caractères | plafond de colonne | `src/document/display_name.cr:32` |
| Longueur du corpus `search` | 256 caractères | plafond de colonne | `src/document/search.cr:33` |

## Rétention et journal des mutations

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Rétention des mutations (historique) | 180 jours ; `0` conserve pour toujours | `mutations.retention_days` (épinglable à l’exécution) | `src/mutation/config.cr:37-40` |
| Surcharge de rétention par doctype | non définie (fichier uniquement) | `mutations.retention_overrides` | `src/mutation/config.cr:55` |
| Cron de compactage | `45 3 * * *` | `mutations.compaction_cron` | `src/mutation/config.cr:61` |
| Fenêtre de fusion à l’écriture des mises à jour | 3 minutes ; `0` désactive | `mutations.coalesce_window_minutes` | `src/mutation/config.cr:84` |
| Rétention du contenu des tombstones | 30 jours ; `0` conserve pour toujours | `tombstone.content_retention_days` (épinglable à l’exécution) | `src/config.cr:258-260` |
| Cron de purge des tombstones | `15 4 * * *` | `tombstone.prune_cron` | `src/config.cr:258-260` |
| Intervalle des instantanés périodiques | toutes les 10 mutations | `snapshot_every` | `src/config.cr:36` |
| Plafond de retour arrière d’un cluster d’audit | 1,000 mutations | constante | `src/audit/rollback.cr:103` |

## Webhooks et livraison

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Timeout de livraison | 10 s par tentative | `webhook.timeout_s` | `src/webhook/config.cr:42` |
| Tentatives de livraison | 5, avec backoff 10 / 60 / 300 / 1,800 / 7,200 s | `webhook.max_attempts`, `webhook.backoff_seconds` | `src/webhook/config.cr:43-48` |
| Schéma d’URL autorisé | https uniquement par défaut | `webhook.allow_insecure_urls` | `src/webhook/config.cr:42-48` |
| Hôtes autorisés | non défini (tout hôte public) | `webhook.allowed_hosts` | `src/webhook/config.cr:42-48` |
| Cron de réconciliation | `7 */1 * * *` | `webhook.reconcile_cron` | `src/webhook/config.cr:42-48` |
| Fenêtre de réconciliation | 24 heures — doit rester sous `jobs.retention_days`, validé au démarrage | `webhook.reconcile_window_hours` | `src/webhook/config.cr:42-48`, `src/config.cr:470-478` |

## Jobs, événements et cron

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Rétention des lignes de jobs | 30 jours | `jobs.retention_days` | `src/jobs/config.cr:31-37` |
| TTL du bail d’un job | 60 s | `jobs.lease_ttl_s` | `src/jobs/config.cr:31-37` |
| TTL du bail long d’un job | 3,600 s | `jobs.long_lease_ttl_s` | `src/jobs/config.cr:31-37` |
| Taille de lot des jobs | 32 | `jobs.batch` | `src/jobs/config.cr:31-37` |
| maxlen du flux d’événements | 1,000,000 entrées | `event.stream.maxlen` | `src/event/config.cr:35-38` |
| Partitions d’événements | 16, 32 au maximum | `event.stream.partitions` | `src/event/config.cr:35-38` |
| Seuil d’alerte de retard des événements | 100,000 entrées | `event.stream.lag_warn_entries` | `src/event/config.cr:35-38` |

## Base de données et MCP

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Timeout des requêtes SQL | non défini (aucun timeout) par défaut | `database.statement_timeout_ms` | `src/config.cr:88-90`, `src/database.cr:154-167` |
| Réponse au timeout des requêtes | `503` sur les chemins d’agrégats | — | `src/http/responders.cr:107`, `src/http/rest_routes.cr:217-219` |
| Lignes de résultat MCP | 200 (plafonne les `items` de l’agent) | `mcp.max_result_rows` | `src/config.cr:218-222`, `src/agent_tools/history.cr:249` |
| Octets de réponse MCP | 1,048,576 (après sérialisation) | `mcp.max_response_bytes` | `src/config.cr:218-222`, `src/agent_tools/caps.cr:34` |
| Opérations par lot MCP | 25 (lève `Capped`) | `mcp.max_batch_ops` | `src/config.cr:218-222`, `src/agent_tools/write.cr:359` |
| Concurrence MCP par session | 4 | `mcp.max_concurrency_per_sid` | `src/config.cr:218-222` |
| Durée des requêtes MCP | bornée par le timeout des requêtes SQL partagé | `database.statement_timeout_ms` | `src/config.cr:213` |
| TTL d’obsolescence du cache | 300 s | `cache.staleness_ttl_s` | `src/config.cr:286` |
| Abonnés WebSocket par collection | 32 par doctype | `websocket.max_subscribers_per_doctype` | `src/config.cr:301` |
| Boîte de réception WebSocket | 64 messages | constante | `src/websocket/connection.cr:76` |

## Bac à sable Lua

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Budget d’instructions | 1,000,000 | défaut du moteur | `src/lua/engine.cr:82-84` |
| Budget mémoire | 32 MB | défaut du moteur | `src/lua/engine.cr:82-84` |
| Budget de temps | 0.5 s | défaut du moteur | `src/lua/engine.cr:82-84` |

La section de configuration `lua:` se charge
(`src/config.cr:168-171,603-612`), mais le bac à sable ne la lit pas —
`src/lua/sandbox.cr:33-35` construit toujours le moteur avec les défauts
ci-dessus. Augmenter ces clés ne change rien tant que le raccordement n’est
pas fait. Enregistré sous l’écart #28.

## Assistant

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Fenêtre du budget de tokens | 30 jours glissants | `WINDOW_DAYS` | `src/assistant/limits.cr:27` |
| Budget de tokens | le maximum parmi les rôles qui l’autorisent ; non défini = illimité | rôle `assistant_token_budget` | `src/assistant/access.cr:81-100` |
| Rétention du registre d’usage | 0 (jamais) par défaut ; 31 jours ou plus sans risque | `assistant.usage_retention_days` (épinglable à l’exécution) | `src/assistant/config.cr:63-71,89` |
| Timeout d’un tour | 900 s | `assistant.turn_timeout_seconds` | `src/assistant/config.cr:86-87` |
| TTL du signal d’annulation | 15 s | `assistant.cancel_ttl_seconds` | `src/assistant/config.cr:86-87` |
| Plafond du titre d’une conversation | 120 caractères | constante | `src/assistant/routes.cr:65` |
| Plafond de la source du titre automatique | 60 caractères | constante | `src/assistant/title.cr:16` |

## Identité et sécurité

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Longueur minimale du mot de passe | 8 caractères | constante | `src/iam/routes.cr:828` |
| Seuil de verrouillage du mot de passe | 10 tentatives échouées par compte, fenêtre de 300 s | `MAX_PWD_ATTEMPTS` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:94` |
| Seuil de verrouillage par IP | 20 tentatives échouées par IP, fenêtre de 300 s | `MAX_IP_ATTEMPTS` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:116` |
| Plafond d’émission de défis MFA | 5 défis, fenêtre de 300 s | `MAX_CHALLENGE_ISSUES` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:140` |
| Limitation du changement de mot de passe | 5 échecs en 300 s | `MAX_CHANGE_PASSWORD_ATTEMPTS` | `src/iam/routes.cr` (limitation des connexions), `src/iam/login_throttle.cr` |
| Longueur du nom d’une clé API | 100 caractères | constante | `src/iam/api_key.cr:49` |
| TTL du token d’accès | 900 s | `iam.access_token_ttl` | `src/iam/config.cr:66-69` |
| TTL du refresh token | 1,209,600 s (14 jours) | `iam.refresh_token_ttl` | `src/iam/config.cr:66-69` |
| Période de grâce du refresh token | 10 s | `iam.refresh_grace_seconds` | `src/iam/config.cr:66-69` |
| Fenêtre `iat` du DPoP | −10 s / +30 s | constantes | `src/iam/config.cr:66-69` |
| TTL du lien d’informations d’identification | 86,400 s (24 h) | `iam.change_password_expiration` (épinglable à l’exécution) | `src/iam/config.cr:62` |
| Limite de débit des tokens OAuth | 30 requêtes par 300 s par (client, IP) | `DEFAULT_CAP` | `src/oauth/rate_limiter.cr:56-62` |
| Clé maîtresse des secrets | ≥ 32 octets décodés | `secrets.master_key` | `src/secrets/config.cr:35` |
| Coût bcrypt | 12 | `secrets.bcrypt_cost` | `src/secrets/config.cr:44-48` |
| TTL des secrets en préparation | 900 s | `secrets.staging_ttl` | `src/secrets/config.cr:44-48` |

## Index et identifiants

| Limite | Valeur | Clé de configuration / constante | Source |
| --- | --- | --- | --- |
| Longueur de l’identifiant d’un index | 63 caractères | constante | `src/index/naming.cr:15` |
| Tentatives de DDL d’index | 3 | constante | `src/index/manager.cr:47` |
| Plancher de sondage du watcher de domaines en dev | 100 ms | `dev.domain_watch.poll_ms` | `src/dev/config.cr:66` |

## Clés épinglables à l’exécution

Une partie de ces limites est aussi un chemin de `core.SystemSettings` : un
opérateur l’épingle depuis la page des paramètres, sans redéploiement. En font
partie `mutations.retention_days`, `tombstone.content_retention_days`,
`artifact.grant_prune_days`, `artifact.grant_ttl_seconds`,
`artifact.grant_ttl_media_seconds`, `artifact.prune_after_days`, les réglages
de l’assistant (`max_tokens`, `max_history`, `temperature`) et
`iam.change_password_expiration`. La liste complète se trouve dans
`src/system_settings/spec.cr:108-190`. Le fichier de configuration reste la
solution de repli pour chaque clé épinglée.

## Voir aussi

- [Fichiers de configuration](/fr/admin/configure/configuration-files/) — toutes les sections et toutes les clés de configuration.
- [Paramètres système](/fr/admin/configure/system-settings/) — les clés épinglables à l’exécution.
- [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) — la sonde de santé et les métriques que ces limites alimentent.
- [Rétention : ce qui est gardé](/fr/admin/history/retention/) — les fenêtres de rétention en contexte.
