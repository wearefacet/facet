---
type: how-to
title: Envoyer des webhooks
description: Livrez à un endpoint HTTPS externe des événements de changement signés, à partir d’un doctype.
audience: [author, developer]
features: [AUT-03]
sidebar:
  order: 1
verified_at: eee55a2
---

Votre système de facturation doit savoir au moment où une réservation est confirmée, et il vit en dehors de Facet. À chaque changement de document, un webhook pousse un événement signé vers votre système : vous enregistrez une URL cible sur un doctype source, vous choisissez les événements, et Facet livre chaque correspondance à votre endpoint en HTTP POST. Cette page n’exige pas de Lua, mais le récepteur a besoin de code pour vérifier la signature.

## Quand l’utiliser

- Un système externe doit réagir en quelques secondes à des documents nouveaux ou modifiés.
- Vous alimentez un entrepôt de données ou un index de recherche depuis Facet.
- Vous préférez votre propre code aux scripts dans Facet.

## Avant de commencer

- **Une cible HTTPS publique.** Votre cible doit être une URL HTTPS sur un hôte qui se résout publiquement. Un récepteur interne qu’un déploiement veut réellement autoriser est nommé dans `webhook.allowed_hosts` de la configuration du serveur.
- **Le canal `webhook`.** Votre rôle doit porter le [canal de connectivité](/fr/admin/people/roles-and-permissions/) `webhook` ; un rôle limité au navigateur ne peut pas créer de webhooks. L’entrée **Webhooks** n’apparaît dans le menu du compte que pour les rôles qui détiennent le canal.
- **La page.** Trouvez-la sous **Paramètres → Webhooks**. Vous gérez les webhooks que vous avez créés ; un administrateur voit tous.

## Créer le webhook

Sélectionnez **Créer un webhook** et remplissez :

| Champ | Signification |
| --- | --- |
| Libellé | Un nom pour la liste. |
| URL cible | La cible HTTPS du POST. |
| Doctype source | Le doctype à observer. |
| Événements | Désactivez **Déclencher sur tous les événements** pour nommer ceux que vous voulez. |
| En-têtes personnalisés | En-têtes facultatifs fusionnés dans chaque POST, pour l’authentification côté récepteur. |

Facet génère un secret de signature et lie le webhook à votre compte. Le lien est permanent : le webhook reste le vôtre, et le secret, le compte lié et le rôle lié ne peuvent plus être modifiés ensuite.

La liste d’événements est un vocabulaire fermé : les verbes de changement (`created`, `updated`, `deleted`), les événements de réparation (`migrated`, `rolled_back`), et un ensemble d’événements à adhésion explicite. Un webhook « tous événements » ne reçoit jamais un événement à adhésion explicite — par exemple, `notified` reste privé pour son destinataire, et `child_changed` transporte une enveloppe plutôt qu’un corps de document — sauf si la liste le nomme explicitement. Les événements d’actions nommées (comme `booking_confirmed`) sont dynamiques par doctype : vous ne pouvez pas les taper dans la liste, mais un webhook « tous événements » les reçoit. Un nom inconnu est rejeté à l’enregistrement, avec les noms autorisés dans le message.

## Vérifier la signature

Chaque livraison porte l’en-tête `X-Facet-Signature: sha256=<hex>`. Le hex est le HMAC-SHA256 du corps brut exact, avec votre secret comme clé. Vérifiez-le avant de faire confiance à un payload — cet exemple utilise Node.js :

```js
import { createHmac, timingSafeEqual } from 'node:crypto';

export function verify(rawBody, secret, header) {
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex');
  return timingSafeEqual(Buffer.from(expected), Buffer.from(header));
}
```

Lisez le corps brut en texte avant de l’analyser, et comparez avec ces octets exacts. La table complète des en-têtes et la grammaire du corps se trouvent dans la [référence des payloads webhook](/fr/reference/webhook-payloads/).

## Lire le payload

Le corps est une enveloppe JSON. Les champs principaux :

| Champ | Signification |
| --- | --- |
| `event` | Le nom de l’événement, par exemple `created`. |
| `domain`, `doc_type`, `doc_id` | Le document qui a changé. |
| `actioner_id`, `cause` | Le compte qui a fait le changement et sa trace de cause. |
| `content` | Le payload de l’événement. Un changement de document ordinaire ne transporte que la trame d’identifiant `{"id": "<doc_id>"}`, jamais le corps du document. Récupérez le document via l’API quand vous avez besoin de son contenu. Un événement à adhésion explicite qui transporte plus le transporte — par exemple, `notified` transporte l’enregistrement de notification. |
| `mutation_id`, `emitted_at` | L’identité du changement et son heure. |
| `delivery_id` | Unique par livraison. |

Facet ajoute des en-têtes sur lesquels vous pouvez router : `X-Facet-Event`, `X-Facet-Delivery` et `X-Facet-Mutation-Id`.

## Ce que la livraison garantit

Un seul paragraphe franc, parce qu’il compte : la mise en file qui confie un événement à la file de livraison peut se perdre dans une panne rare — un défaut de publication, une indisponibilité du consommateur, un flux tronqué. Un travail de réconciliation répare cela : chaque heure, il rejoue la décision de mise en file à partir du journal des changements durable, pour la dernière `webhook.reconcile_window_hours` (24 heures par défaut). Le transport après la mise en file retente avec un délai croissant, jusqu’à cinq tentatives. Les deux moitiés ensemble signifient qu’un événement peut arriver en retard et, dans une course avec le passage de réparation, deux fois — il ne disparaît jamais en silence dans la fenêtre. Rendez votre récepteur idempotent : clé sur `mutation_id` et `delivery_id`. Le pipeline derrière cela se trouve dans [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/).

## Suivre le journal des appels

Ouvrez **Appels** sur une ligne de webhook. Chaque tentative est listée avec son statut et la réponse du récepteur. Un appel qui échoue retente avec un délai croissant — 10 secondes, puis 1 minute, 5 minutes, 30 minutes et 2 heures. Sélectionnez **Tester** pour envoyer une sonde synthétique et lire la réponse comme donnée ; la sonde arrive aussi dans le journal des appels. Vous pouvez **Rejouer** un appel journalisé à la main.

## Mettre en pause, ne pas supprimer

Basculez **Activé** sur désactivé pour mettre les livraisons en pause. Facet conserve les réglages, le secret et le journal des appels. La suppression retire la cible pour de bon — les livraisons déjà en file s’exécutent encore, mais rien de nouveau n’arrive.

## Exemple

Un webhook observe les réservations Brightwater. Après que Nadia confirme la réservation `BK-2026-0001`, Facet envoie ce corps en POST au récepteur :

```json
{
  "webhook_id": "core.Webhook.01JCATPMKP4N82GVG2J7K4MHZZ",
  "delivery_id": "01JD5R7X4K92Q8WVBN6P3A1YCD",
  "event": "booking_confirmed",
  "domain": "rentals",
  "doc_type": "Booking",
  "doc_id": "rentals.Booking.BK-2026-0001",
  "mutation_id": "01JD5R6Y8K31N4TQZ9W2B5XDEG",
  "actioner_id": "iam.Account.01JD5R5T2M80K3P7N1Q4S6V9WX",
  "cause": { "kind": "request", "trace": "01JD5R6Y8K31N4TQZ9W2B5XDEG" },
  "content": { "id": "rentals.Booking.BK-2026-0001" },
  "emitted_at": "2026-12-07T09:15:02Z"
}
```

Le récepteur vérifie la signature, récupère la réservation par `doc_id` et répond `200`. Toute autre réponse compte comme un échec et démarre l’échelle de réessais.

## Dépannage

**Rien n’arrive.**

Vérifiez, dans l’ordre : le webhook est activé ; le doctype source correspond ; l’événement est dans la liste ; le rôle lié peut encore lire le doctype. Le journal des appels montre une raison d’écart quand une barrière refuse une livraison.

**La signature ne se vérifie jamais.**

Vous hachez l’objet analysé. Hachez les octets bruts du corps de la requête.

**Une URL interne est refusée.**

Les cibles doivent se résoudre publiquement. Un administrateur peut nommer des hôtes internes dans `webhook.allowed_hosts` de la configuration du serveur.

**Le même événement est arrivé deux fois.**

Un réessai après un dépassement de délai, ou le passage de réparation en course avec une mise en file lente, peut livrer deux fois. Dédupliquez sur `mutation_id` et `delivery_id`.

## Voir aussi

- [Payloads webhook](/fr/reference/webhook-payloads/) — chaque champ et chaque en-tête.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) — le pipeline d’événements derrière les webhooks.
- [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) — exécuter un script dans Facet sur les mêmes événements.
