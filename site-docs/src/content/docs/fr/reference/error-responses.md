---
title: Réponses d’erreur
description: "Formes des réponses d’erreurà : 422 de validation, échecs d’authentification et 404 sans divulgation."
audience: [developer, operator]
features: [PLT-13]
sidebar:
  order: 8
verified_at: f1409cdc
---

Utilisez cette page pour lire une erreur renvoyée par l’API, ou pour
construire la gestion d’erreurs dont votre client a besoin.

Chaque erreur renvoyée par l’API est un objet JSON avec une clé `error`. Les
échecs de validation ajoutent un tableau `details`. Toutes les réponses
d’erreur sont en `application/json` et portent `Cache-Control: no-store`.

Cette page donne les codes de statut, les formes du corps, et ce que chaque
refus permet à un appelant de conclure.

## Forme du corps

```json
{ "error": "<message>", "details": [ ... ], "<extra>": "<value>" }
```

| Partie | Présence | Contenu |
| --- | --- | --- |
| `error` | toujours | Le message lisible par un humain. En anglais, jamais localisé. |
| `details` | échecs de validation seulement | Un objet par valeur rejetée. Omis quand vide. |
| clés supplémentaires | quelques statuts seulement | Des valeurs chaînes à plat qu’une route ajoute, par exemple les champs de pierre tombale sur un `410`. |

## Codes de statut

| Statut | Renvoyé quand | Notes du corps |
| --- | --- | --- |
| `400` | Un corps JSON mal formé sur une route de création, ou une requête QUERY dont le corps ne déclare pas de `Content-Type`. | Nomme l’erreur d’analyse. |
| `401` | Un identifiant présenté est invalide ou inexploitable. | `{"error": "Authentication required"}`. |
| `403` | L’appelant n’a aucune permission pour l’opération, ou échoue au contrôle de requête intersites. | `{"error": "Forbidden"}` pour les refus de permission. |
| `404` | Le document est absent, ou l’appelant a une attribution mais ne peut pas voir la ligne. Aussi pour une route inconnue, un doctype inconnu ou un domaine désactivé. | Sans divulgation — voir plus bas. |
| `405` | Le chemin répond à d’autres méthodes. | Porte l’en-tête `Allow` ; le message nomme le même ensemble. |
| `409` | Une écriture concurrente a perdu la course d’ordonnancement, un enregistrement de doctype en double, ou un conflit d’état comme restaurer un document non supprimé. | `{"error": "Concurrent write on this document — retry the request"}` pour la course d’écriture. Renvoyez la même requête. |
| `410` | Le document existe sous forme de pierre tombale. | Porte `X-Document-Deleted: true`, plus `display_name` et `deleted_at` quand ils sont connus. |
| `415` | La requête déclare un type de média non JSON l à où la route attend du JSON. | |
| `422` | La validation a échoué, le corps a une forme incorrecte, ou un paramètre de requête est inconnu. | Porte `details` quand la validation de champs a échoué. |
| `500` | Une défaillance inattendue. | Toujours `{"error": "Internal server error"}` — jamais le texte d’une exception. Les détails vont dans le journal du serveur. |
| `503` | Un agrégat de liste a dépassé le timeout d’instruction. | Réessayez avec un filtre plus étroit. |

## Forme de validation 422

Chaque entrée de `details` décrit une valeur rejetéeà :

| Champ | Présence | Contenu |
| --- | --- | --- |
| `field` | quand l’erreur nomme un champ | Chemin séparé par des points. Les indices de tableau sont des segments numériques nusà : `items.3.name`. |
| `message` | toujours | Le texte de repli en anglais. |
| `code` | quand le producteur en appose un | Une étiquette machine stable sur laquelle se brancher. |
| `params` | quand le code est un gabarit | Un objet `{name: value}` à plat avec les interpolations. |

Les codes stablesà :

| Code | Signification |
| --- | --- |
| `required` | Un champ obligatoire est absent ou null. |
| `invalid_type` | La valeur ne correspond pas au type déclaré du champ. |
| `unknown_field` | L’entrée porte une clé que le doctype ne déclare pas. |
| `read_only` | L’appelant a défini un champ en lecture seule ou répliqué. |
| `reserved` | L’entrée utilise un nom de champ réservé par le système. |
| `unique` | Une contrainte d’unicité a été violée. |
| `invalid_format` | La valeur est mal formée pour son format, par exemple un motif ou une clé d’énumération. |
| `inactive_currency` | Une valeur monétaire nomme une devise enregistrée mais inactive. |
| `out_of_range` | Une borne numérique ou de longueur a été violée. |
| `compute` | Une fonction de calcul a appelé `error(msg)`. |
| `compute_runtime` | Une fonction de calcul a levé une exception inattendue. |
| `script` | Un hook de cycle de vie ou une action a appelé `ctx.error(msg)`. |
| `rbac` | Une définition de permission RBAC a échoué à la validation d’écriture. |
| `context_set` | Une définition d’ensemble de contexte de domaine est mal formée. |
| `named_scope` | Un périmètre nommé référence un ensemble de contexte non déclaré. |
| `schema` | Un contrôle au niveau de la définition de doctype a échoué. |
| `template` | Un modèle de vue a échoué à la validation structurelle. |
| `argument` | Un argument d’action nommée est absent ou invalide. |

Branchez sur `code`, jamais sur le texte de `message`.

### Exemple

Une création qui envoie une valeur d’énumération que le doctype ne déclare
pasà :

```sh
curl -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title": "Fix login", "status": "archived"}' \
  "https://facet.example.com/Api/helpdesk/Ticket"
```

La réponse està :

```json
{
  "error": "Document validation failed",
  "details": [
    {
      "field": "status",
      "message": "has invalid enum value 'archived' (allowed: active, inactive)",
      "code": "invalid_format",
      "params": {
        "value": "archived",
        "allowed": "active, inactive",
        "format": "one of: active, inactive"
      }
    }
  ]
}
```

Un client qui exploite `params` peut afficher le refus dans la langue de
l’utilisateurà ; sinon, il affiche `message`.

## 404 sans divulgation

Une lecture ou une écriture de document répond de l’une de ces trois
façonsà :

| Situation | Réponse |
| --- | --- |
| L’appelant n’a aucune attribution pour l’action sur le doctype | `403` |
| L’appelant a une attribution, mais la ligne ne correspond pas au périmètre de lignes de l’attribution — ou la ligne n’existe pas | `404` |
| La ligne est une pierre tombale et l’appelant pourrait sinon la lire | `410` |

Le `404` est délibérément sans divulgation : un document inaccessible est
indistinguable d’un document absent. Un appelant peut conclure que l’id ne
désigne aucun document lisible. Un appelant ne peut rien conclure surà :

- si le document existe,
- qui peut le voir,
- pourquoi le périmètre n’a pas correspondu.

Ce contrat protège les documents dont les ids sont énumérables. Gardez-le
intact dans votre propre gestion d’erreursà :

- Affichez le même corps pour les deux causes.
- Ne sondez pas les ids pour cartographier la portée d’un rôle — chaque refus
  est journalisé côté serveur.

Les listes se comportent autrement, par conception : une liste à périmètre se
réduit en silence et répond `200` avec les lignes visibles, éventuellement un
ensemble vide.

## Erreurs d’authentification et d’autorisation

| Situation | Réponse |
| --- | --- |
| Aucun identifiant | La requête tourne sous le rôle `anonymous` créé par l’initialisation. Ses droits de lecture sont la surface publiqueà ; tout ce qui les dépasse répond `403`. |
| Un identifiant est présenté mais invalide — expiré, signature erronée, en-tête `Authorization` inexploitable, schéma inconnu | `401` `{"error": "Authentication required"}`. Un identifiant cassé ne bascule jamais vers l’accès anonyme. |
| Un refus de permission sur une route de document ou de fonctionnalité | `403` `{"error": "Forbidden"}`. |
| Une requête qui change l’état, depuis une session cookie, sans l’en-tête `X-Requested-With` | `403` `{"error": "CSRF: Missing X-Requested-With header"}`. |

Une requête qui porte `Authorization: Bearer` est exemptée du contrôle
d’en-tête — une clé d’API, un token d’app ou un token d’agent. Une requête de
navigateur intersites ne peut pas porter cet en-tête.

## Voir aussi

- [API REST](/fr/reference/rest-api/) — la surface d’endpoints à laquelle
  appartiennent ces statuts.
