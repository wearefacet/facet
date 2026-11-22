---
title: Les périmètres de lignes
description: "Resserez une ligne de permission du doctype entier aux lignes qu’un rôle peut voir ou changer."
audience: [admin, author]
features: [RBC-05, DOM-12]
sidebar:
  order: 4
verified_at: fd345fe3
---

Une ligne de permission atteint un doctype entier, ou seulement les lignes
qui répondent à une condition. Un périmètre de lignes nomme cette condition.
Le doctype déclare ses périmètres une fois ; un rôle s’y réfère par alias et
n’écrit jamais ses propres prédicats.

:::note[Cette page est une moitié d’une paire]
Cette page couvre le côté **admin** : attacher un alias à un rôle et voir
comment Facet l’applique. Le côté **auteur** — déclarer le périmètre et
l’ensemble de contexte qu’il lit — vit dans
[Les périmètres nommés](/fr/build/named-scopes/). L’[exemple
complet](#exemple-complet-ses-projets-via-les-équipes) ci-dessous montre les
deux moitiés ensemble.
:::

## Quand l’utiliser

- Un rôle ne peut voir ou changer que ses propres lignes.
- Un rôle peut voir des lignes qui répondent à une règle partagée, par
  exemple chaque projet actif.
- Plusieurs rôles partagent une règle de lignes, et vous voulez la déclarer
  une fois.

## Avant de commencer

- **La grammaire.** Vous connaissez la grammaire des lignes de permission —
  voir [Rôles et lignes de permission](/fr/govern/roles-permission-lines/).
- **La déclaration.** Les périmètres doivent exister sur la définition du
  doctype avant qu’un rôle puisse s’y référer. Les étapes d’écriture vivent
  dans [Les périmètres nommés](/fr/build/named-scopes/).

## Explication

### Où vivent les périmètres

La définition du doctype porte les périmètres sous `scopes`. Chaque entrée
est un filtre `where` sur les champs propres au doctype :

```yaml
# définition production.Project
scopes:
  mine:
    description: "Projects owned by the actioner"
    where:
      owner_id: "$self"
  global:
    description: "Projects with no owner"
    where:
      owner_id: "$null"
  active:
    description: "Projects in the active status"
    where:
      status: "active"
```

Les rôles choisissent dans ce catalogue. Ils ne peuvent pas ajouter un
prédicat à eux sur une ligne de permission. La grammaire de `where` :

| Valeur                   | Correspond à                                                                                                                                      |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"active"`               | La valeur stockée littérale.                                                                                                                        |
| `"$self"`                | L’id du compte agissant. Il correspond à la fois à la forme référence `iam.Account.<id>` et à un id nu, si bien qu’un même périmètre fonctionne sur un champ propriétaire de type référence comme de type chaîne. |
| `"$my_teams"`            | Les valeurs d’un ensemble de contexte déclaré par le domaine, résolues à chaque requête. Un ensemble vide ou irrésoluble ne correspond à aucune ligne, même avec `ne`.                 |
| `"$null"`                | Les lignes où le champ est absent ou null en JSON. Ne marche qu’avec `eq`.                                                                          |
| `"$organizational_unit"` | Le chemin en arborescence du compte agissant, par exemple `/engineering/backend/`.                                                                  |

Une clé `where` peut porter un suffixe d’opérateur, comme les filtres de
liste : `priority__gte`, `title__starts_with`, `price__between`. Une clé nue
signifie égal. Un champ accepte exactement les opérateurs que ses capacités
`filters` déclarées permettent. Deux clés réservées existent : `$parent_id`
lit le lien parent, et `$doc_id` lit l’id de la ligne. Toutes deux ne
prennent que `eq` ou `ne`.

### Ce que dit une ligne de permission

Lisez chaque ligne avec son effet :

```json
{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}
```

Cette ligne laisse un membre lire les projets qu’il possède et les projets
sans propriétaire.

```json
{"action": "update", "on": "crm.Deal", "scope": ["$mine"]}
```

Cette ligne laisse un membre modifier les affaires qu’il possède, et aucune
autre.

```json
{"action": "read", "on": "production.Project", "scope": "$all"}
```

Cette ligne laisse un membre lire chaque projet. `$all` est la forme
explicite sans restriction ; omettre `scope` veut dire la même chose. Dans
un tableau, `$all` ramène toute la ligne à l’absence de restriction.

### Comment Facet applique un périmètre

- **Les listes.** Le périmètre se compile en fragment SQL `WHERE`. Une liste
  avec périmètre répond `200` avec les lignes qui correspondent,
  éventuellement aucune. Un périmètre de lignes ne devient jamais un `403`.
- **Les lectures individuelles, les mises à jour, les suppressions et les
  actions.** Le contrôleur vérifie la ligne contre le périmètre. Une ligne
  qui échoue répond le même `404` qu’un document manquant, si bien que la
  réponse ne révèle jamais que le document existe.
- **La création.** Aucune ligne n’existe encore, donc le périmètre ne tourne
  pas à la création. Le périmètre voyage jusqu’au hook de création Lua
  comme canal d’intention qui peut positionner des valeurs de champs, par
  exemple le propriétaire. La vérification du domaine signale un
  avertissement par ligne de création avec périmètre sur le domaine `iam`.
- **La redéfinition.** Modifiez un périmètre sur le doctype, et chaque rôle
  qui référence l’alias utilise le nouveau prédicat dès la requête suivante.
  Aucune édition de rôle n’est nécessaire.
- **Le resserrement à la requête.** Les routes de liste et d’agrégat et les
  outils d’agent acceptent `scope=<name>`. Cela ne fait que resserrer ce
  que l’appelant voit déjà. Un nom inconnu répond `422`.
- **Les requêtes sans identifiant.** Elles tournent sous le rôle
  `anonymous`. `$self` se résout à la valeur littérale `anonymous`, qui ne
  correspond à aucun compte ; les périmètres `$self` restent donc inertes.
  `$organizational_unit` se résout au chemin racine `/`.

:::caution[L’alias doit exister sur le doctype cible]
Un alias de périmètre se résout contre le doctype que la ligne cible. Une
ligne qui nomme un alias que le doctype ne déclare pas échoue à la
validation quand vous enregistrez le rôle.
:::

## Exemple

Un administrateur resserre un rôle d’édition sur `production.Project` :

1. L’auteur déclare les périmètres `mine`, `global` et `active` ci-dessus.
2. Le rôle porte la ligne de lecture avec `["$mine", "$global"]` et la ligne
   de mise à jour avec `$mine`, toutes deux reprises ci-dessus.
3. Un membre avec ce rôle liste les projets. Facet renvoie les projets que
   le membre possède plus chaque projet sans propriétaire, et rien d’autre.
4. Le membre ouvre un projet qu’il possède et le modifie. La modification
   s’enregistre.
5. Le membre ouvre un projet qu’un autre compte possède. La lecture répond
   `404`, alors que le projet existe.
6. Le membre liste avec `?scope=active` et n’obtient que le sous-ensemble
   actif de ce qu’il voyait déjà.

## Dépannage

### Une liste avec périmètre renvoie des lignes inattendues

Les alias d’un tableau se combinent en OU. Vérifiez si une ligne porte plus
d’alias que voulu, ou si `$all` se trouve dans le tableau.

### Un membre reçoit `404` sur un document qui existe

La ligne a échoué à la vérification du périmètre. C’est la réponse sans
divulgation, par conception — voir
[Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).

### L’API répond `Unknown scope`

Le nom du périmètre n’est pas déclaré sur le doctype visé par la ligne.
Copiez le nom depuis la définition.

### Une ligne de création avec périmètre s’enregistre avec un avertissement

La création ignore les périmètres, par conception. Déplacez la règle de
lignes dans un hook de création — voir
[Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/).

## Exemple complet, ses projets via les équipes

Un rôle `project_manager` ne lit que les projets de sa propre équipe. Les
projets appartiennent à une équipe, et une équipe porte des lignes membres
qui nomment un compte. La règle demande deux déclarations — une sur le
domaine, une sur le doctype — puis une ligne de rôle nomme le périmètre.

### Le modèle de documents

- **Team → TeamMember** est une composition : `Team` est la racine
  d’agrégat, `TeamMember` son enfant (`member_of: Team`), et chaque ligne
  membre porte une référence `account` vers `iam.Account`. Un doctype
  `TeamMember` dédié convient ici, parce qu’une appartenance est une ligne
  qui a sa propre vie, et qu’un compte peut siéger dans plusieurs équipes.
- **Project → Team** est une référence : `Project.team` pointe vers
  `projects.Team`.

<!-- d2
Account: iam.Account {class: external}
Team: projects.Team {class: node}
Member: projects.TeamMember {class: node}
Project: projects.Project {class: node}
Set: my_teams context set {class: info}
Scope: team_projects scope {class: info}
Role: project_manager role {class: accent}

Team -> Member: children / member_of
Member -> Account: account
Project -> Team: team
Set -> Member: reads membership
Set -> Scope: resolves for
Scope -> Project: where team
Role -> Scope: references alias
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e3030573-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e3030573-dark.svg" alt="Diagram" loading="lazy" />
</div>

Le diagramme montre les deux relations de données, les deux déclarations qui
les lisent, et le rôle qui nomme le périmètre. Les déclarations d’écriture
(la paire `children`/`member_of`, le champ référence, l’ensemble de contexte
`my_teams`, et le périmètre `team_projects`) sont sur
[Les périmètres nommés](/fr/build/named-scopes/#exemple-complet-ses-projets-via-les-équipes).
La partie admin suit.

### La ligne du rôle

Le rôle `project_manager` porte une ligne de lecture sur `projects.Project` :

```json
{
  "action": "read",
  "on": "projects.Project",
  "scope": ["$team_projects"]
}
```

`team_projects` est un périmètre que le doctype déclare, avec
`where: { team: "$my_teams" }`. L’ensemble de contexte `$my_teams` se
résout, à chaque requête, aux ids des équipes auxquelles l’appelant
appartient.

### Ce que voit le manager

1. La personne appartient à deux équipes. Une liste de `projects.Project`
   renvoie les projets des deux équipes, et rien d’autre.
2. Une lecture directe d’un projet d’une autre équipe répond `404`, alors
   que le projet existe — la réponse sans divulgation de
   [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).
3. La personne rejoint une nouvelle équipe. La requête suivante résout le
   nouvel ensemble `my_teams` et renvoie les projets de la nouvelle équipe.
   Aucune édition de rôle n’est nécessaire.

## Voir aussi

- [Les périmètres nommés](/fr/build/named-scopes/) — déclarez les périmètres
  et leurs ensembles de contexte sur le doctype et le domaine.
- [Rôles et lignes de permission](/fr/govern/roles-permission-lines/) — la
  grammaire des lignes autour de `scope`.
- [Visibilité des champs par étiquettes](/fr/govern/field-visibility-tags/) —
  resserrer au niveau des champs de la même façon.
- [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/) —
  où siègent les contrôleurs.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
