---
title: Payloads des webhooks
description: Champs du payload de webhook, en-tête de signature et vérification de la signature.
audience: [developer, operator]
features: [AUT-03]
sidebar:
  order: 7
verified_at: 008dd880
---

Utilisez cette page pour lire un corps de webhook et vérifier sa signature
dans votre récepteur.

Une livraison de webhook tient en un seul POST HTTP. Le corps est une
enveloppe JSON de forme fixe, et chaque livraison porte un en-tête de
signature calculé à partir du secret du webhook lui-même.

Cette page décrit les champs du corps, les en-têtes et le calcul de
vérification.

## La requête POST

| En-tête | Valeur |
| --- | --- |
| `Content-Type` | `application/json`. Un en-tête personnalisé du même nom le remplace. |
| `User-Agent` | `Facet-Webhook/1.0`. Un en-tête personnalisé du même nom le remplace. |
| `X-Facet-Signature` | `sha256=<hex>` — la signature. Ne se remplace jamais. |
| `X-Facet-Event` | Le nom de l’événement, identique au `event` du corps. |
| `X-Facet-Delivery` | L’id de livraison, identique au `delivery_id` du corps. |
| `X-Facet-Webhook-Id` | L’id du webhook, identique au `webhook_id` du corps. |
| `X-Facet-Mutation-Id` | L’id de mutation, quand l’événement en porte un. |
| `X-Facet-Origin` | `webhooks:<webhook_id>`. |

Les en-têtes personnalisés du document webhook fusionnent après les
valeurs par défaut. Les clés d’en-tête qui commencent par `X-Facet-`
sont refusées à la rédaction, si bien qu’un en-tête personnalisé ne peut
jamais masquer ceux ci-dessus.

## Champs du corps

Le corps est un objet JSON. Les champs apparaissent toujours dans cet
ordre, et la signature couvre ces octets exacts :

| Champ | Type | Contenu |
| --- | --- | --- |
| `webhook_id` | string | L’id qualifié du document `core.Webhook`. |
| `delivery_id` | string | Un id neuf pour cette tentative de livraison. |
| `event` | string | Le nom de l’événement. Voir le tableau ci-dessous. |
| `domain` | string | Le domaine du document source. |
| `doc_type` | string | Le nom de doctype du document source. |
| `doc_id` | string | L’id qualifié du document source. Pour un événement de cycle de vie de job, l’id du job. |
| `mutation_id` | string \| null | La mutation qui a causé l’événement, quand elle existe. Les événements de cycle de vie de job n’en portent pas. |
| `actioner_id` | string \| null | L’id qualifié du compte qui a fait le changement. |
| `cause` | object \| null | La chaîne de cause : `kind`, plus `name`, `event`, `source`, `parent`, `trace` facultatifs. |
| `content` | object | Le payload de l’événement. Voir le tableau ci-dessous. |
| `emitted_at` | string | Timestamp RFC 3339 UTC de l’événement. |

Les champs de transport du document webhook — `url`, `secret`,
`headers` — n’apparaissent jamais dans le corps.

### Le champ `content` par famille d’événements

| Famille d’événements | Contenu de `content` |
| --- | --- |
| Mutations de document : `created`, `updated`, `deleted`, une action nommée, `migrated`, `rolled_back` | `{ "id": "<doc_id>" }` — une trame d’id de document, pas un corps de document. Récupérez le document via l’API quand vous avez besoin de son contenu. |
| `child_changed` | `{ "id", "action", "child": {"doc_type", "doc_id"}, "parent": {"doc_type", "doc_id"} }` — la trame de changement de l’agrégat parent. |
| `notified` | `{ "id", "notification": { ... } }` — l’enregistrement de notification : `notification_id`, `account_id`, `kind`, `title`, `body`, `data`, `actions`, `created_at`, et les pointeurs du document. |
| Cycle de vie de job : `export_completed`, `export_failed`, `import_completed`, `import_failed`, et les quatre noms `domain_*` | `{ "id": "<job_id>", "export" \| "import": { ... } }` — le rapport du job : des comptages comme `row_count`, `created`, `updated`, `skipped`, plus `artifact_id` et `format` quand ils s’appliquent. |

### Noms d’événements

Un webhook se lie à un doctype source et à une liste de noms
d’événements.

- **Omettre la liste `events`** déclenche la livraison pour les
  événements standard.
- **Donner une liste vide** ne déclenche rien.

| Nom | Se déclenche pour | Opt-in |
| --- | --- | --- |
| `created`, `updated`, `deleted` | Mutations de document du doctype source. | non |
| `migrated`, `rolled_back` | Rejeux de la migration différée et restaurations par retour arrière. | non |
| Noms d’actions nommées | Un événement par action exécutée. Le nom de l’événement est la clé de l’action au passé — `approve_document` devient `document_approved` — ou le `event_name` déclaré de l’action. | non |
| `notified` | Événements de notification destinés à un compte. | oui |
| `child_changed` | Changements des enfants possédés de l’agrégat lié. | oui |
| `export_completed`, `export_failed`, `import_completed`, `import_failed` | Jobs d’import/export de documents. | oui |
| `domain_export_completed`, `domain_export_failed`, `domain_import_completed`, `domain_import_failed` | Jobs de domaine portable sur `core.Domain`. | oui |

Un événement opt-in ne se déclenche que si la liste `events` du webhook
le nomme. Un webhook sans liste `events` n’en reçoit jamais.

## La signature

L’en-tête de signature est :

```text
X-Facet-Signature: sha256=<lowercase hex of HMAC-SHA256(secret, raw_body)>
```

- La clé est le champ `secret` du document webhook — un id généré par le
  serveur, posé à la création et lisible par l’auteur du webhook. Il
  n’existe aucune clé de signature commune à tout le serveur.
- Le message est le corps brut de la requête, exactement tel que le
  récepteur le lit sur le fil. Ne resérialisez pas le JSON avant de
  vérifier.
- Le condensé est hexadécimal en minuscules, sur 64 caractères.

### Vérification — Node.js

```js
const crypto = require("crypto");

function verifySignature(rawBody, secret, header) {
  const expected =
    "sha256=" +
    crypto.createHmac("sha256", secret).update(rawBody, "utf8").digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(header);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = { verifySignature };
```

Lisez `rawBody` depuis les octets de la requête d’origine, avant toute
analyse JSON ou re-sérialisation. La vérification de longueur évite que
`timingSafeEqual` ne lève une erreur sur un en-tête mal formé.

### Vérification — openssl

```sh
EXPECTED="sha256=$(printf '%s' "$RAW_BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -hex | sed 's/^.* //')"
[ "$EXPECTED" = "$SIGNATURE_HEADER" ] && echo valid || echo invalid
```

## Livraison et comportement des relances

| Aspect | Comportement |
| --- | --- |
| Délai d’attente du transport | 10 secondes par tentative, connexion et lecture cumulées. |
| Succès | Tout statut `2xx`. Tout autre statut, `3xx` inclus, et toute erreur de transport comptent comme un échec. |
| Relances | Jusqu’à 5 tentatives par livraison, avec des délais de 10, 60, 300, 1800 et 7200 secondes. Ce sont les valeurs par défaut ; la section `webhook` de la configuration les remplace. |
| Redirections | Non suivies. |
| Livraisons en double | Possibles. Un réconciliateur répare la mise en file et peut entrer en concurrence avec le chemin direct. |
| Ordre | Non garanti. Utilisez `emitted_at` et `mutation_id` pour détecter et réordonner. |

Les récepteurs doivent tolérer les doublons et les livraisons tardives.
Stockez le `delivery_id` des livraisons traitées quand vous avez besoin
d’effets appliqués une seule fois de votre côté.

## Exemple complet

Un webhook sur le doctype `accountancy.Contract` livre :

```json
{
  "webhook_id": "core.Webhook.01JHWK3QZ0M4T7R2V9X6B8ND5P",
  "delivery_id": "01JHWK3R2W5Y8C0F4G7J1M6T9Q",
  "event": "updated",
  "domain": "accountancy",
  "doc_type": "Contract",
  "doc_id": "accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A",
  "mutation_id": "01JHWK3N8A2D6H0M4P9S3V7X1Z",
  "actioner_id": "iam.Account.01JHWK36D9G3K7Q1W5E8R4T2Y0",
  "cause": {
    "kind": "request",
    "trace": "01JHWK3N8A2D6H0M4P9S3V7X1Z"
  },
  "content": {
    "id": "accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A"
  },
  "emitted_at": "2026-11-13T09:30:00Z"
}
```

Avec le secret de webhook `01JHWK3S8X2M5P7R0T3V6Y9B2D`, l’en-tête de
signature sur ce corps — sérialisé sans espaces — est :

```text
X-Facet-Signature: sha256=8cce667b2e605b0e4ea17ee9d2ccc0d74464576b5c555810f98eb09d66e03b0c
```

Vous pouvez reproduire le condensé sur la même forme compacte :

```sh
printf '%s' '{"webhook_id":"core.Webhook.01JHWK3QZ0M4T7R2V9X6B8ND5P","delivery_id":"01JHWK3R2W5Y8C0F4G7J1M6T9Q","event":"updated","domain":"accountancy","doc_type":"Contract","doc_id":"accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A","mutation_id":"01JHWK3N8A2D6H0M4P9S3V7X1Z","actioner_id":"iam.Account.01JHWK36D9G3K7Q1W5E8R4T2Y0","cause":{"kind":"request","trace":"01JHWK3N8A2D6H0M4P9S3V7X1Z"},"content":{"id":"accountancy.Contract.01JHWK3K5F8B2N6R0T4W8Y2C6A"},"emitted_at":"2026-11-13T09:30:00Z"}' \
  | openssl dgst -sha256 -hmac "01JHWK3S8X2M5P7R0T3V6Y9B2D" -hex | sed 's/^.* //'
```

La commande affiche
`8cce667b2e605b0e4ea17ee9d2ccc0d74464576b5c555810f98eb09d66e03b0c`.
Une vraie livraison signe les octets tels qu’envoyés ; l’exemple signe
la forme compacte pour que vous puissiez l’exécuter tel quel.

## Voir aussi

- [Webhooks sortants](/fr/build/webhooks/) — enregistrer et gérer les webhooks.
- [Hooks d’événements](/fr/build/event-hooks/) — exécuter du Lua dans Facet au lieu d’appeler l’extérieur.
