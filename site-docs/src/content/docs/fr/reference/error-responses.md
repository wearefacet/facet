---
type: reference
title: Réponses d’erreur
description: "Formes des réponses d’erreur : 422 de validation, échecs d’authentification et 404 sans divulgation."
audience: [developer, operator]
features: [PLT-13]
sidebar:
  order: 18
verified_at: eee55a2
---

Votre client appelle l’API et reçoit une erreur. Cette page présente la forme
du corps, chaque statut que l’API peut renvoyer, et les codes de validation
sur lesquels brancher. Vous y apprenez aussi ce que chaque refus permet de
conclure — et ce qu’il ne dit jamais.

## Forme du corps

Chaque erreur est un unique objet JSON avec une clé `error`. Toutes les
réponses d’erreur sont en `application/json` et portent
`Cache-Control: no-store`. Les navigateurs peuvent mettre en cache les
réponses `404` et `410` par défaut, et une pierre tombale en cache
continuerait à déclarer un document supprimé après sa restauration.

```json
{ "error": "<message>", "details": [ ... ], "<extra>": "<value>" }
```

| Partie | Présence | Contenu |
| --- | --- | --- |
| `error` | toujours | Le message lisible par un humain. En anglais, jamais localisé. |
| `details` | échecs de validation uniquement | Un objet par valeur rejetée. Omis quand vide. |
| clés supplémentaires | quelques statuts uniquement | Des chaînes à plat qu’une route ajoute, par exemple les champs de la pierre tombale sur un `410` ou la clé `dependency` sur un `503`. |

## Codes de statut

| Statut | Renvoyé quand | Notes sur le corps |
| --- | --- | --- |
| `400` | Un corps JSON mal formé sur une route de création, ou une requête QUERY dont le corps ne déclare pas de `Content-Type`. | Nomme l’erreur d’analyse. |
| `401` | L’identifiant présenté est invalide ou inexploitable. | `{"error": "Authentication required"}`. |
| `403` | L’appelant n’a aucune permission pour l’opération, échoue au contrôle de requête intersites, ou écrit dans un champ invisible. | `{"error": "Forbidden"}` pour les refus de permission ; les refus d’écriture portent leurs propres messages — voir le tableau ci-dessous. |
| `404` | Le document est absent, ou l’appelant détient une attribution mais ne peut pas voir la ligne. Aussi pour une route inconnue, un doctype inconnu ou un domaine désactivé. | Sans divulgation — voir plus bas. |
| `405` | Le chemin répond à d’autres méthodes. | Porte l’en-tête `Allow` ; le message nomme le même ensemble. |
| `409` | Une écriture concurrente a perdu la course d’ordonnancement, un doublon d’enregistrement de doctype ou de nom de domaine, ou un conflit d’état comme la restauration d’un document non supprimé. | `{"error": "Concurrent write on this document — retry the request"}` pour la course d’écriture. Renvoyez la même requête. |
| `410` | Le document existe sous forme de pierre tombale — lecture d’un document supprimé, ou suppression d’un document déjà supprimé. | Porte `X-Document-Deleted: true`, plus `display_name` et `deleted_at` quand ils sont connus. |
| `413` | Un téléversement — artefact de fichier, import de document ou import de domaine — dépasse la limite de taille. | `{"error": "Upload exceeds the maximum allowed size (N bytes)"}` avec la valeur de la limite. |
| `415` | La requête déclare un type de média non JSON là où la route attend du JSON : corps QUERY, écriture de document imbriqué, ou corps `export_view`. | Le message nomme la route qui a refusé. |
| `422` | La validation a échoué, le corps a une forme incorrecte, ou un paramètre de requête est inconnu. | Porte `details` quand la validation de champs a échoué. |
| `429` | Un rate limit ou un budget est atteint : le plancher de refresh OAuth (`slow_down`), une limite IAM (verrouillage de connexion, vérification MFA, changement de mot de passe), ou le budget de tokens de l’assistant. | Le message indique quel mécanisme a déclenché. L’endpoint de token OAuth définit aussi `Retry-After`. |
| `500` | Une défaillance inattendue. | Toujours `{"error": "Internal server error"}` — jamais le texte d’une exception. Les détails vont dans le journal du serveur. |
| `502` | La route de test de messagerie a atteint un transport qui a refusé ou fait échouer la requête. | Le message contient l’erreur renvoyée par l’adaptateur. |
| `503` | Soit une liste ou un export a dépassé le timeout d’instruction, soit un service sous-jacent (Redis, PostgreSQL) était injoignable. | Deux formes — voir plus bas. |

### Les refus d’écriture 403

Un `403` sur une écriture peut nommer sa raison :

| Message | Signification | Source |
| --- | --- | --- |
| `Forbidden` | L’appelant n’a aucune permission pour cette action sur le doctype (refus de rôle ou plafond des attributions de l’app). | `src/document/read.cr:174-182`, `src/document/action.cr:239-251` |
| `Write refused: invisible field` | L’écriture touche un champ que le rôle de l’appelant ne peut pas voir — un `null` explicite compte comme une écriture. `details` nomme les chemins de contenu. | `src/rbac/write_enforcer.cr:75` |
| `Role authority refused this write` | L’écriture déplacerait un compte ou un rôle IAM au-dessus du niveau de l’appelant, ou vers une cible protégée. | `src/rbac/role_authority.cr:390-393` |

### Les deux formes de 503

| Forme | Cause | Que faire |
| --- | --- | --- |
| `{"error": "The request exceeded the server's statement timeout — narrow the filters and retry"}` | Une requête de liste, d’export ou d’agrégat a dépassé `database.statement_timeout_ms`. | Réduisez les filtres et réessayez. |
| `{"error": "Service unavailable", "dependency": "redis" \| "postgresql"}` | Une défaillance de connexion d’un service sous-jacent. | Un signal pour l’opérateur, pas un bogue client — vérifiez la sonde de santé. |

## La forme de validation 422

Chaque entrée de `details` décrit une valeur rejetée :

| Champ | Présence | Contenu |
| --- | --- | --- |
| `field` | quand l’erreur nomme un champ | Chemin séparé par des points. Les indices de tableau sont des segments numériques nus : `items.3.name`. |
| `message` | toujours | Le texte de repli en anglais. |
| `code` | quand le producteur en appose un | Une étiquette machine stable sur laquelle brancher. |
| `params` | quand le code est un gabarit | Un objet `{name: value}` à plat avec les interpolations. |

Les codes stables :

| Code | Signification |
| --- | --- |
| `required` | Un champ obligatoire est absent ou null. |
| `invalid_type` | La valeur ne correspond pas au type déclaré du champ. |
| `unknown_field` | L’entrée porte une clé que le doctype ne déclare pas. |
| `read_only` | L’appelant a défini un champ en lecture seule ou répliqué. |
| `reserved` | L’entrée utilise un nom de champ réservé par le système. |
| `unique` | Une contrainte d’unicité a été violée. La course perdue sur l’index unique porte aussi ce code. |
| `invalid_format` | La valeur est mal formée pour son format — un motif, une clé d’énumération, une forme d’URL, un token de référence. |
| `invalid_reference_format` | Une valeur de référence n’utilise pas la forme `domain.Doctype.id`. |
| `reference_target_not_found` | La cible référencée n’existe pas comme ligne active. |
| `reference_doctype_mismatch` | Une valeur de référence nomme un doctype que le champ ne déclare pas. |
| `reference_filter_mismatch` | La ligne référencée existe mais ne satisfait pas le `filter` du champ, ou l’appelant ne peut pas la lire. |
| `duplicate_reference_target` | Une référence de collection nomme deux fois la même cible. |
| `inactive_currency` | Une valeur monétaire nomme une devise enregistrée mais inactive. |
| `out_of_range` | Une borne numérique ou de longueur a été violée. |
| `too_long` | Une valeur dépasse un plafond fixe, par exemple la longueur d’une clé d’énumération. |
| `empty_value` | Une valeur qui doit être non vide porte un texte vide. |
| `duplicate_value` | Une liste au niveau de la définition porte deux fois la même clé, par exemple une énumération. |
| `invalid_value` | Une valeur est en dehors de l’ensemble qu’une règle autorise, par exemple la couleur d’une colonne de kanban. |
| `invalid_mime` | Les octets du fichier téléversé ne correspondent pas aux types MIME autorisés du champ. |
| `immutable` | Une écriture tente de changer un champ qui ne peut plus changer après la création, par exemple l’email d’un compte. |
| `unsupported_field` | Une configuration de vue nomme un champ que la surface ne prend pas en charge. |
| `wildcard_target` | Une attribution d’app nomme le wildcard `domain.*` au lieu d’une cible concrète. |
| `unsupported_filter_operator` | Le champ ne prend pas en charge l’opérateur que le filtre utilise. |
| `malformed_filter_value` | La valeur du filtre a une forme incorrecte, par exemple un `__between` qui n’est pas un tableau. |
| `compute` | Une fonction de calcul a appelé `error(msg)`. |
| `compute_runtime` | Une fonction de calcul a levé une exception inattendue. |
| `script` | Un hook de cycle de vie ou une action a appelé `ctx.error(msg)`. |
| `rbac` | Une définition de permission RBAC a échoué à la validation au moment de son écriture. |
| `context_set` | Une définition d’ensemble de contexte de domaine est mal formée. |
| `named_scope` | Un périmètre nommé référence un ensemble de contexte non déclaré. |
| `schema` | Un contrôle au niveau de la définition de doctype a échoué. |
| `template` | Un modèle de vue a échoué à la validation structurelle. |
| `argument` | Un argument d’action nommée est absent ou invalide. |
| `forbidden` | Le refus d’écriture `Write refused: invisible field` — les détails portent les chemins invisibles. |

Branchez sur `code`, jamais sur le texte de `message`.

### Exemple

Une création qui envoie une valeur d’énumération que le doctype ne déclare
pas :

```sh
curl -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"title": "Fix login", "status": "archived"}' \
  "$(facet-cli host)/Api/helpdesk/Ticket"
```

La réponse est :

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

Un client qui affiche `params` peut présenter le refus dans la langue de
l’utilisateur ; un client qui ne le fait pas affiche `message`.

## Le 404 sans divulgation

Une lecture ou une écriture de document répond de l’une de ces trois façons :

| Situation | Réponse |
| --- | --- |
| L’appelant n’a aucune attribution pour l’action sur le doctype | `403` |
| L’appelant détient une attribution, mais la ligne échappe au périmètre de lignes de l’attribution — ou la ligne n’existe pas | `404` |
| La ligne est une pierre tombale et l’appelant pourrait sinon la lire | `410` |

Le `404` est délibérément sans divulgation : un document inaccessible est
indistinguable d’un document absent. L’appelant peut conclure que l’id ne
désigne aucun document lisible. Il ne peut rien conclure sur :

- l’existence du document,
- les personnes autorisées à le voir,
- la raison pour laquelle le périmètre n’a pas correspondu.

Ce contrat protège les documents dont les ids sont énumérables. Préservez-le
dans votre propre gestion d’erreurs :

- Renvoyez le même corps pour les deux causes.
- Ne sondez pas les ids pour cartographier la portée d’un rôle — chaque refus
  est journalisé côté serveur.

Les listes se comportent autrement, par conception : une liste à périmètre se
réduit en silence et répond `200` avec les lignes visibles, éventuellement un
ensemble vide.

## Erreurs d’authentification et d’autorisation

| Situation | Réponse |
| --- | --- |
| Aucun identifiant | La requête tourne sous le rôle `anonymous` pré-créé. Ses droits de lecture forment la surface publique ; tout ce qui les dépasse répond `403`. |
| Un identifiant est présenté mais invalide — expiré, signature erronée, en-tête `Authorization` inexploitable, schéma inconnu | `401` `{"error": "Authentication required"}`. Un identifiant cassé ne bascule jamais vers l’accès anonyme. |
| Un refus de permission sur une route de document ou de fonctionnalité | `403` `{"error": "Forbidden"}`. |
| Une requête qui modifie l’état, émise depuis une session cookie sans l’en-tête `X-Requested-With` | `403` `{"error": "CSRF: Missing X-Requested-With header"}`. |

Une requête qui porte `Authorization: Bearer` est exemptée du contrôle
d’en-tête — clé d’API, token d’app ou token d’agent. Une requête de navigateur
intersites ne peut pas porter cet en-tête.

## Voir aussi

- [API REST](/fr/reference/rest-api/) — la surface d’endpoints à laquelle
  appartiennent ces statuts.
- [Utiliser l’API REST](/fr/build/apps/data/rest-api/)
