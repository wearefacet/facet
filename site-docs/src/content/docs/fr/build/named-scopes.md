---
title: Les périmètres nommés
description: Déclarez des filtres de lignes réutilisables sur un doctype et attachez-les aux permissions d’un rôle.
audience: [author, admin]
features: [DOM-12]
sidebar:
  order: 16
verified_at: f1409cdc
---

Un périmètre nommé est un filtre enregistré sur les champs d’un doctype. Un
administrateur l’attache à une ligne de permission, et la permission
n’atteint alors que les lignes que le filtre retient. Les périmètres gardent
les règles de lignes à un seul endroit : le filtre appartient au doctype,
les rôles ne font que le nommer.

:::note[Cette page est une moitié d’une paire]
Cette page couvre le côté **auteur** : déclarer le périmètre et l’ensemble
de contexte qu’il lit. Le côté **admin** — attacher un alias à un rôle et
voir comment Facet l’applique — vit dans
[Les périmètres de lignes](/fr/govern/row-scopes/). L’[exemple
complet](#exemple-complet-ses-projets-via-les-équipes) ci-dessous montre les
deux moitiés ensemble.
:::

## Quand l’utiliser

- Un rôle ne peut voir ou modifier que ses propres lignes.
- Plusieurs rôles partagent une même règle de lignes, et vous ne voulez pas
  la répéter.
- Un lecteur a besoin d’un sous-ensemble enregistré via l’API, par exemple
  « projets actifs ».

## Avant de commencer

- **Côté auteur :** vous modifiez la définition du doctype pour y déclarer
  les périmètres.
- **Côté admin :** un administrateur modifie le rôle pour les attacher. Le
  modèle de permissions complet est traité dans les pages d’accès — cette
  page reste du côté auteur.

## Étapes

### 1. Déclarer les périmètres sur le doctype

Ajoutez un bloc `scopes` à la définition du doctype. Chaque entrée porte une
description et un filtre `where` :

```yaml
scopes:
  mine:
    description: "Projects owned by the actioner"
    where:
      owner_id: "$self"
  active:
    description: "Projects in the active status"
    where:
      status: "active"
  open:
    description: "Projects with no owner yet"
    where:
      owner_id: "$null"
```

Les valeurs de `where` suivent une seule grammaire :

| Valeur | Correspondance |
| --- | --- |
| `"active"` | La valeur stockée exacte. |
| `"$self"` | L’id du compte appelant. Fonctionne sur un champ référence comme sur un champ chaîne simple qui stocke un id de compte. |
| `"$null"` | Les lignes où le champ est absent. |
| `"$my_teams"` | Les lignes dont la valeur du champ figure dans l’ensemble qu’un ensemble de contexte résout. L’ensemble est une requête que le domaine déclare ; Facet l’exécute à chaque requête pour le compte appelant et compare les valeurs des lignes au résultat. Un ensemble vide ou en échec ne retient aucune ligne. |
| `"$organizational_unit"` | Le chemin d’unité organisationnelle du compte appelant. |

Un nom de champ peut porter un suffixe d’opérateur, comme les filtres de
liste : `priority__gte`, `title__match`, `price__between`. Un nom nu
signifie égal.

La forme `$<name>` est générique : tout nom qui n’est ni `$self`, ni
`$null`, ni `$organizational_unit` est un ensemble de contexte. `$my_teams`
n’est que le nom habituel de « les équipes auxquelles le compte appelant
appartient ». Pour en utiliser un, déclarez l’ensemble de contexte sur le
document du domaine — pas sur le doctype — sous **Configurer → Domaines →
(le domaine) → Octrois → Ensembles de contexte** :

```yaml
# production domain document, under content
context_sets:
  my_teams:
    from: TeamMember   # a doctype of the same domain
    where:
      account: "$self"
    select: "$parent_id"  # the field to collect; $parent_id reads the parent team
```

`from` désigne le doctype à interroger, `where` filtre ses lignes, et
`select` nomme le champ à collecter dans l’ensemble. `where` et `select`
acceptent `$self`, `$parent_id`, `$doc_id` et d’autres ensembles de
contexte : un ensemble peut donc s’appuyer sur un autre.

### 2. Attacher les périmètres à un rôle

Un administrateur ouvre le rôle dans **Configurer → Accès**, trouve le
doctype et règle le périmètre d’une action. La liste déroulante propose
**Tout** plus chaque périmètre déclaré sur le doctype. Plusieurs périmètres
sur une même ligne se combinent en OU : la permission atteint les lignes
qui répondent à l’un d’eux.

La ligne de permission stockée ressemble à ceci :

```json
{
  "action": "read",
  "on": "production.Project",
  "scope": ["$mine", "$open"]
}
```

Cette ligne donne la lecture des projets que le lecteur possède **ou** des
projets que personne ne possède. Une ligne sans périmètre atteint toutes les
lignes.

### 3. Utiliser un périmètre comme filtre enregistré

N’importe quel lecteur peut passer un périmètre déclaré comme filtre sur la
route de liste. Il ne fait que resserrer ce que l’appelant peut déjà
voir :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/production/Project?scope=active"
```

## Exemple

Le parcours complet sur un doctype `production.Project`, avec un champ
référence `owner_id` et un champ énumération `status` :

1. L’auteur déclare les périmètres `mine` et `active` de l’étape 1.
2. Un administrateur règle l’action **Lecture** du rôle éditeur de champs sur
   `["$mine", "$active"]` dans l’éditeur de rôles.
3. Un lecteur avec ce rôle liste les projets. Facet renvoie les projets que
   le lecteur possède ainsi que tous les projets actifs, et rien d’autre. Un
   projet possédé par quelqu’un d’autre avec le statut `planned` reste
   caché.
4. Le même lecteur appelle la route de liste avec `?scope=active` et
   n’obtient que le sous-ensemble actif.

## Dépannage

**Le sélecteur de périmètre du rôle ne propose que Tout.**

Le doctype ne déclare pas encore de périmètres, ou l’enregistrement de la
définition a échoué. Ajoutez le bloc `scopes` et revérifiez le doctype.

**Une liste avec périmètre ne renvoie rien.**

Le filtre ne retient aucune ligne. Vérifiez la forme de la valeur
stockée : un champ référence stocke un id qualifié, mais `"$self"` le
reconnaît quand même ; un littéral doit correspondre exactement à la valeur
stockée. Pour une valeur d’ensemble de contexte, vérifiez que l’ensemble se
résout pour ce compte : un ensemble vide, ou un ensemble dont le `where` ne
retient aucune ligne, ne retient aucune ligne de la liste non plus.

**L’API répond « Unknown scope ».**

Le nom du périmètre n’est pas déclaré sur ce doctype. Reprenez le nom de la
définition.

**Un changement de rôle reste sans effet.**

Les permissions s’appliquent à la requête suivante. Rechargez la liste et
vérifiez que le rôle a été enregistré sur le bon chemin de doctype, par
exemple `production.Project`.

## Exemple complet, ses projets via les équipes

Un chef de projet lit uniquement les projets de sa propre équipe. Les
projets appartiennent à une équipe, une équipe a des membres, et chaque
membre désigne un compte. Un ensemble de contexte et un périmètre nommé
expriment cela, et le rôle référence le périmètre par son alias.

### Le modèle de documents

Deux relations portent la règle :

- **Team → TeamMember** est une composition. `Team` est la racine d’agrégat
  et `TeamMember` est son enfant (`member_of: Team`). Chaque ligne de membre
  porte une référence `account` vers `iam.Account`.
- **Project → Team** est une référence. `Project` porte une référence `team`
  vers `projects.Team`.

<!-- d2
Account: iam.Account {class: external}
Team: projects.Team {class: node}
Member: projects.TeamMember {class: node}
Project: projects.Project {class: node}
Set: my_teams context set {class: info}
Scope: team_projects scope {class: info}

Team -> Member: children / member_of
Member -> Account: account
Project -> Team: team
Set -> Member: reads membership
Set -> Scope: resolves for
Scope -> Project: where team
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/b8c9ce6e-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/b8c9ce6e-dark.svg" alt="Diagram" loading="lazy" />
</div>

Le diagramme montre les deux relations de données et les deux déclarations
qui les lisent.

Un doctype `TeamMember` séparé est la bonne forme ici : l’appartenance est
une ligne avec sa propre vie (date d’entrée, rôle dans l’équipe), et un même
compte peut siéger dans plusieurs équipes. Un unique champ référence
`members` sur `Team` ferait aussi l’affaire pour une liste simple, mais un
doctype enfant donne à chaque appartenance ses propres champs et son propre
journal d’audit.

```json
// projects.Team — the aggregate root
{
  "domain": "projects",
  "doctype": "Team",
  "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true }
  },
  "children": {
    "members": { "doctype": "TeamMember", "collection": true }
  }
}
```

```json
// projects.TeamMember — the child; the parent link is implicit
{
  "domain": "projects",
  "doctype": "TeamMember",
  "member_of": "Team",
  "fields": {
    "account": { "type": "reference", "doctype": "iam.Account", "required": true }
  }
}
```

```json
// projects.Project — points at its team
{
  "domain": "projects",
  "doctype": "Project",
  "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true },
    "team": { "type": "reference", "doctype": "projects.Team", "filters": ["equality"] }
  }
}
```

Voir [Composition parent/enfant](/fr/build/parent-child-composition/) pour
la paire `children`/`member_of`, et [Références et liens
entrants](/fr/build/references-links-backlinks/) pour les champs référence.

### Étape 1 — l’ensemble de contexte résout les équipes de l’appelant

Déclarez `my_teams` sur le document du domaine `projects`. Il interroge les
lignes `TeamMember` de l’appelant et collecte l’id de l’équipe parente de
chaque ligne :

```yaml
# projects domain document, under content
context_sets:
  my_teams:
    from: TeamMember        # a doctype of the same domain
    where:
      account: "$self"      # the caller's own membership rows
    select: "$parent_id"    # the parent team id of each row
```

`$parent_id` lit le lien parent de l’enfant, si bien que l’ensemble porte les
ids des équipes auxquelles l’appelant appartient — résolus à chaque requête.

### Étape 2 — le périmètre nommé transforme les équipes en filtre de lignes

Déclarez un périmètre sur `projects.Project` qui retient les lignes dont
`team` figure dans cet ensemble :

```yaml
# projects.Project definition
scopes:
  team_projects:
    description: "Projects of the caller's teams"
    where:
      team: "$my_teams"
```

`$my_teams` n’est pas intégré — c’est l’ensemble de contexte déclaré à

l’étape 1. Tout `$<name>` qui n’est ni `$self`, ni `$null`, ni
`$organizational_unit` se résout comme un ensemble de contexte : les deux
déclarations sont donc reliées par ce nom.

### Étape 3 — le rôle nomme le périmètre

Un administrateur règle l’action **Lecture** du rôle `project_manager` sur
`team_projects`. La ligne stockée est :

```json
{
  "action": "read",
  "on": "projects.Project",
  "scope": ["$team_projects"]
}
```

Un chef de projet qui appartient à deux équipes liste `projects.Project` et
voit les projets des deux équipes, et rien d’autre. Un projet d’une équipe à

laquelle il n’appartient pas répond `404` à une lecture directe,
exactement comme un document manquant. Voir
[Les périmètres de lignes](/fr/govern/row-scopes/) pour la façon dont le
contrôleur applique l’alias à la liste, à la lecture et à l’écriture.

## Voir aussi

- [Les périmètres de lignes](/fr/govern/row-scopes/) — attachez un périmètre à un rôle et voyez comment Facet l’applique.
- [Référence de la syntaxe des permissions](/fr/reference/permission-syntax/) — la grammaire complète des permissions.
- [Rôles, niveaux et garde-fou](/fr/concepts/roles-levels-authority/) — comment les rôles et les permissions se relient.
- [Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/) — surveillez les écritures comme vous filtrez les lectures.
