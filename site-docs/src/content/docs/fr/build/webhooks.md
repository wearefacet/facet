---
title: Webhooks sortants
description: Livrez des événements de changement signés depuis un doctype vers un endpoint HTTPS externe.
audience: [author, developer]
features: [AUT-03]
sidebar:
  order: 23
verified_at: f1409cdc
---

Un webhook pousse un événement signé vers votre système à chaque changement
d’un document. Vous enregistrez une URL cible sur un doctype source, choisissez
les événements, et Facet délivre chaque correspondance à votre endpoint sous
forme de POST HTTP.

## Quand l’utiliser

- Un système externe doit réagir en quelques secondes à des documents nouveaux
  ou modifiés.
- Vous alimentez un entrepôt de données ou un index de recherche depuis Facet.
- Vous préférez votre propre code aux scripts internes à Facet.

## Avant de commencer

- **Une cible HTTPS publique.** Votre cible doit être une URL HTTPS sur un hôte
  qui se résout publiquement.
- **Le canal `webhook`.** Votre rôle doit porter le canal de connectivité
  `webhook` ; un rôle limité au navigateur ne peut pas créer de webhooks.
- **La page.** Trouvez-la sous **Paramètres → Webhooks**. Vous gérez les
  webhooks que vous avez créés ; un administrateur voit tout.

## Étapes

### 1. Créez le webhook

Sélectionnez **Créer un webhook** puis renseignez :

| Champ | Signification |
| --- | --- |
| Label | Un nom pour la liste. |
| URL cible | La cible HTTPS du POST. |
| Doctype source | Le doctype à observer. |
| Événements | Laissez vide pour tous, ou nommez ceux que vous voulez. |

Facet génère un secret de signature et lie le webhook à votre compte. La liaison
est définitive : le webhook reste le vôtre.

### 2. Vérifiez la signature

Chaque livraison porte l’en-tête `X-Facet-Signature: sha256=<hex>`. La valeur
hexadécimale est le HMAC-SHA256 du corps brut exact, calculée avec votre secret
comme clé. Vérifiez-la avant de faire confiance à un payload — cet exemple
utilise Node.js :

```js
import { createHmac, timingSafeEqual } from 'node:crypto';

export function verify(rawBody, secret, header) {
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex');
  return timingSafeEqual(Buffer.from(expected), Buffer.from(header));
}
```

Lisez le corps brut comme texte avant de l’analyser, puis vérifiez la signature
sur ces octets exacts.

### 3. Lisez le payload

Le corps est une enveloppe JSON. Les champs principaux :

| Champ | Signification |
| --- | --- |
| `event` | Le nom de l’événement, par exemple `created`. |
| `domain`, `doc_type`, `doc_id` | Quel document a changé. |
| `actioner_id`, `cause` | Le compte qui a fait le changement et sa chaîne de cause. |
| `content` | Le payload de l’événement. Un simple changement de document n’embarque que la trame d’identifiant `{"id": "<doc_id>"}`, jamais le corps du document. Appelez l’API quand vous avez besoin du contenu. Un événement opt-in qui transporte plus de données l’embarque — par exemple `child_changed` embarque l’enveloppe d’agrégat, et `notified` embarque l’enregistrement de notification. |
| `mutation_id`, `emitted_at` | L’identité du changement et son heure. |
| `delivery_id` | Unique par livraison. |

Facet ajoute des en-têtes sur lesquels vous pouvez router : `X-Facet-Event`,
`X-Facet-Delivery` et `X-Facet-Mutation-Id`. Voir la
[référence des payloads de webhook](/fr/reference/webhook-payloads/).

### 4. Surveillez le journal des appels

Ouvrez **Appels** sur une ligne de webhook. Chaque tentative y figure avec son
statut et sa réponse. Un appel en échec réessaie à délai croissant, jusqu’à
cinq tentatives. Sélectionnez **Tester** pour envoyer une sonde de test et
lire la réponse. Vous pouvez rejouer à la main un appel du journal.

:::caution
Les livraisons peuvent se répéter. Une passe de réparation renvoie les
événements manqués à l’intérieur d’une fenêtre récente, et les nouvelles
tentatives peuvent partir deux fois après un timeout. Rendez votre récepteur
idempotent : dédupez sur `mutation_id` et `delivery_id`.
:::

### 5. Désactivez au lieu de supprimer

Désactivez **Activé** pour suspendre les livraisons. Facet conserve les
réglages, le secret et le journal des appels.

## Exemple

Un webhook observe `crm.Company` pour l’événement `created`. Facet envoie ce
corps par POST vers `https://hooks.example.com/facet` :

```json
{
  "webhook_id": "core.Webhook.01JCATPMKP4N82GVG2J7K4MHZZ",
  "delivery_id": "01JD5R7X4K92Q8WVBN6P3A1YCD",
  "event": "created",
  "domain": "crm",
  "doc_type": "Company",
  "doc_id": "crm.Company.01JD5R6Y8K31N4TQZ9W2B5XDEF",
  "mutation_id": "01JD5R6Y8K31N4TQZ9W2B5XDEG",
  "actioner_id": "iam.Account.01JD5R5T2M80K3P7N1Q4S6V9WX",
  "cause": {
    "kind": "request",
    "trace": "01JD5R6Y8K31N4TQZ9W2B5XDEG"
  },
  "content": {
    "id": "crm.Company.01JD5R6Y8K31N4TQZ9W2B5XDEF"
  },
  "emitted_at": "2026-11-13T09:15:02Z"
}
```

Le récepteur vérifie la signature, récupère l’entreprise par son `doc_id`, et
répond `200`. Toute autre réponse compte comme un échec et lance la série de
nouvelles tentatives : 10 secondes, puis 1 minute, 5 minutes, 30 minutes et
2 heures.

## Dépannage

**Rien n’arrive.**

Vérifiez, dans l’ordre : le webhook est activé ; le doctype source correspond ;
l’événement est dans la liste ; le rôle lié peut toujours lire le doctype. Le
journal des appels affiche un motif d’omission quand un garde-fou refuse une
livraison.

**La signature ne se vérifie jamais.**

Vous hachez l’objet analysé. Hachez les octets du corps brut de la requête.

**Une URL interne est refusée.**

Les cibles doivent se résoudre publiquement. Un administrateur peut autoriser
des hôtes internes nommés dans la configuration du serveur.

## Voir aussi

- [Référence des payloads de webhook](/fr/reference/webhook-payloads/) — chaque champ et chaque en-tête.
- [Livraison d’événements](/fr/concepts/events-delivery/) — le pipeline d’événements derrière les webhooks.
- [Hooks d’événements et de planification](/fr/build/event-hooks/) — exécutez un script dans Facet sur les mêmes événements.
