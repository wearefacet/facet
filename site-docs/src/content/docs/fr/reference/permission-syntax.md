---
title: Syntaxe des lignes de permission
description: La grammaire des lignes de permission, avec des exemples et leurs effets.
audience: [admin, developer]
features: [RBC-01, RBC-03, RBC-06]
sidebar:
  order: 5
verified_at: 008dd880
---

Utilisez cette page pour écrire une ligne de permission et vérifier ce que
chaque forme attribue.

Une ligne de permission est un objet JSON dans le tableau `permissions` d’un
document `iam.Roles`. Elle attribue une action sur un chemin de doctype, avec
un périmètre de lignes facultatif et une soustraction de chemins facultative.

Cette page donne la grammaire exacte que l’analyseur accepte et l’effet de
chaque forme.

## Structure d’une ligne

Une ligne porte quatre parties. `action` et `on` sont obligatoires ;
`scope` et `except` sont facultatifs.

```json
{ "action": "<action>", "on": "<domain>.<path>", "scope": ["$<alias>"], "except": ["<domain>.<Doctype>"] }
```

| Partie | Obligatoire | Forme |
| --- | --- | --- |
| `action` | oui | `read`, `create`, `update`, `delete`, `*` (toutes les actions), ou une action nommée comme `activate` ou `publish_artifact`. La correspondance est exacte ; seul `*` est un joker. |
| `on` | oui | Un chemin séparé par des points : le domaine, puis les segments de doctype. Les noms de domaine sont en minuscules avec des tirets ; les segments de doctype sont en CamelCase. |
| `scope` | non | Un tableau de chaînes `$<alias>`. Chaque alias nomme un périmètre déclaré sur le doctype feuille. Les alias se combinent en OU. |
| `except` | non | Un tableau de chemins concrets `domain.Doctype`. Chaque entrée retire son sous-arbre de la ligne. |

L’analyseur normalise chaque ligne vers cette forme. Trois règles valent pour
toutes les formes :

- Un `scope` absent vaut toutes les lignes.
- Un `$all` dans un tableau `scope` réduit la ligne à un accès sans
  restriction.
- Une entrée `except` n’attribue jamais rien. Elle réduit seulement la ligne
  qui la porte.

## Le chemin `on`

| Forme | Correspond à |
| --- | --- |
| `crm.Deal` | Le doctype `crm.Deal`. |
| `crm.Deal.Comment` | Uniquement le doctype enfant imbriqué. |
| `crm` | Tous les doctypes du domaine `crm`. |
| `crm.Project` | `crm.Project` **et** chaque enfant imbriqué comme `crm.Project.Comment` — un chemin parent couvre son sous-arbre. |
| `*.*` | Tous les doctypes de tous les domaines. La seule forme joker. |

Règles que le validateur impose :

- Le segment de domaine doit correspondre à `[a-z][a-z0-9-]*`. Les segments de
  chemin doivent correspondre à `[A-Z][a-zA-Z0-9]*` (CamelCase).
- Le domaine joker `*` n’est valide qu’avec le doctype joker : le chemin
  complet doit être `*.*`. Une forme mixte comme `*.Deal` est une erreur.
- Une ligne `*.*` est une ligne joker. Le garde-fou d’autorité des rôles
  n’autorise à l’écrire que l’appelant dont le propre rôle atteint `*.*`.

## Le champ `scope`

La forme tableau est obligatoire sur tout chemin d’écriture. La forme à chaîne
unique (`"scope": "$mine"`) est une forme ancienne que des rôles stockés
peuvent encore porter ; une écriture de rôle avec un périmètre chaîne échoue
avec `must be an array`.

| Forme | Lignes couvertes |
| --- | --- |
| absent | Toutes les lignes. |
| `"$all"` | Toutes les lignes. Équivalent à l’absence. |
| `["$mine"]` | Les lignes qui correspondent au périmètre `mine` déclaré sur le doctype feuille. |
| `["$mine", "$global"]` | Les lignes qui correspondent à `mine` **ou** `global` — les alias se combinent en OU. |
| `["$all", "$mine"]` | Toutes les lignes. N’importe quelle entrée `$all` réduit tout le tableau. |

Chaque alias doit être déclaré dans le bloc `scopes:` du doctype feuille. Le
validateur rejette un alias inconnu à l’écriture du rôle ; le contrôle le
développe par rapport à la définition réelle au moment de la requête. Un rôle
n’écrit jamais son propre prédicat de requête. Voir
[Périmètres de lignes](/fr/govern/row-scopes/) pour la grammaire de
déclaration.

## Le champ `except`

| Règle | Détail |
| --- | --- |
| Forme d’entrée | Un chemin concret `domain.Doctype`. Au moins deux segments ; aucun `*` nulle part. |
| Correspondance | Une entrée fait une correspondance par préfixe comme `on` : une entrée sur `core.DocType` exclut aussi `core.DocType.Comment`. |
| Effet | Une cible qui correspond à une entrée ne correspond jamais à la ligne, même quand elle correspond à `on`. |
| Validation | Les entrées sont vérifiées à l’analyse. Une entrée mal formée fait échouer l’écriture du rôle. |

`except` est une arithmétique de chemins, pas un système de refus. Il permet à

une ré-attribution à périmètre sur les mêmes chemins de coexister avec une
ligne large.

## Exemples et effets

| Ligne de permission | Effet |
| --- | --- |
| `{"action": "read", "on": "production.Project"}` | Lire toutes les lignes de `production.Project`, et celles de ses doctypes enfants imbriqués. |
| `{"action": "read", "on": "production.Project", "scope": ["$mine"]}` | Lire uniquement les lignes qui correspondent au périmètre `mine`. Une liste ne montre que ces lignes. La lecture d’une autre ligne répond `404`. |
| `{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}` | Lire les lignes que l’appelant possède, plus les lignes sans propriétaire. |
| `{"action": "read", "on": "production.Project", "scope": "$all"}` | Lire toutes les lignes — la forme explicite d’un périmètre omis. Forme chaîne ancienne ; utilisez la forme tableau dans les écritures. |
| `{"action": "read", "on": "hr"}` | Lire tous les doctypes du domaine `hr`. |
| `{"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}` | Mettre à jour tous les documents sauf les deux surfaces de définition et leurs enfants imbriqués. |
| `{"action": "*", "on": "*.*"}` | Toutes les actions sur tous les doctypes. Le rôle `admin` créé par l’initialisation porte cette ligne. |
| `{"action": "activate", "on": "core.DomainGrant"}` | Exécuter l’action nommée `activate` sur `core.DomainGrant`. Lectures, créations, mises à jour et suppressions restent non attribuées. |
| `{"action": "create", "on": "crm.Deal", "scope": ["$mine"]}` | Créer une affaire. Le périmètre n’est **pas** appliqué à la création — aucune ligne n’existe encore à vérifier. C’est un canal d’intention qu’un hook Lua de création lit via `ctx.actor.scope`. Le contrôle de domaine émet un avertissement pour de telles lignes. |

Les réponses du contrôle diffèrent selon la classe de refus :

- Aucune ligne ne correspond à l’action ni au doctype → `403` sur la surface
  contrôlée.
- Une ligne correspond, mais la ligne visée ne répond pas à son périmètre
  (opérations sur un seul document) → le `404` sans divulgation.
- Une requête de liste → le périmètre se compile dans la requête. La liste
  reste réduite au périmètre, éventuellement vide. Une liste à périmètre ne
  devient jamais un `403`.

## Exemple complet

Un rôle pour une équipe de support. Le doctype `helpdesk.Ticket` déclare le
périmètre nommé `unresolved` ; `helpdesk.Ticket.Comment` déclare `mine`.

```json
{
  "name": "support_agent",
  "level": 20,
  "visible_tags": ["default"],
  "permissions": [
    { "action": "read",   "on": "helpdesk.Ticket" },
    { "action": "create", "on": "helpdesk.Ticket" },
    { "action": "update", "on": "helpdesk.Ticket", "scope": ["$unresolved"] },
    { "action": "delete", "on": "helpdesk.Ticket.Comment", "scope": ["$mine"] }
  ]
}
```

Le porteur de ce rôle peut :

- Lire tous les tickets, y compris les commentaires de chaque ticket — la
  ligne `read` couvre le doctype enfant par correspondance de préfixe.
- Créer des tickets. La création est sans restriction.
- Mettre à jour un ticket tant que sa ligne correspond au périmètre
  `unresolved`, par exemple un ticket dont `status` n’est pas `closed`. Une
  mise à jour d’un ticket fermé répond `404`.
- Supprimer ses propres commentaires — les lignes où le périmètre `mine` du
  commentaire correspond, par exemple les lignes que le porteur a rédigées.

  Le même porteur ne peut pas :

- Supprimer des tickets — aucune ligne `delete` n’atteint `helpdesk.Ticket`,
  et une suppression ne passe jamais par la ligne `update`.
- Supprimer le commentaire d’un autre agent — le périmètre `mine` ne
  correspond pas, la réponse est `404`.
- Mettre à jour un ticket fermé — le périmètre `unresolved` ne correspond pas.
- Lire ou écrire quoi que ce soit hors de `helpdesk.Ticket` et de ses
  enfants — tout autre doctype répond `403`.
- Voir les champs étiquetés au-del à de `default` — `visible_tags` vaut
  `["default"]`.

## Visibilité des champs

La visibilité des champs ne fait pas partie d’une ligne de permission. Le rôle
porte un tableau `visible_tags` ; chaque champ porte `tags`. Un champ est
visible quand toutes ses étiquettes figurent dans les étiquettes du rôle. Les
étiquettes par défaut d’un rôle sont `["default"]` ; l’étiquette joker `["*"]`
voit tous les champs. Une écriture dans un champ invisible répond `403`. Voir
[Visibilité des champs par étiquettes](/fr/govern/field-visibility-tags/).

## Voir aussi

- [Rôles et lignes de permission](/fr/govern/roles-permission-lines/) — modifier les documents de rôle.
- [Périmètres de lignes](/fr/govern/row-scopes/) — déclarer et référencer les périmètres.
- [Visibilité des champs par étiquettes](/fr/govern/field-visibility-tags/) — le masque champ par champ.
