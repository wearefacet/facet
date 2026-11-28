---
type: how-to
title: Les périmètres nommés
description: Déclarez des périmètres nommés sur un doctype pour que chaque rôle n’atteigne que les lignes qui correspondent.
audience: [author, admin]
features: [DOM-12]
sidebar:
  order: 0
verified_at: eee55a2
---

Chez Brightwater, chaque commercial ne doit voir que les clients qu’il gère.
Tom traite cinq des dix sociétés ; son collègue s’occupe des autres. Tous
deux portent le même rôle *Sales*, le rôle ne peut donc pas citer des
sociétés : la règle doit dire « vos propres clients ». En tant qu’auteur du
domaine, vous écrivez cette règle une seule fois sur le doctype Company sous
la forme d’un **périmètre nommé** : un filtre enregistré sur les propres
champs du doctype. Un administrateur l’attache ensuite au rôle, et toutes
les surfaces suivent — listes, recherche, API, apps.

:::note[Cette page est une moitié d’une paire]
Cette page couvre le côté **auteur** : déclarer le périmètre et l’ensemble
de contexte qu’il lit. Le côté **admin** — attacher l’alias à un rôle et
voir comment Facet l’applique — se trouve dans
[Les périmètres de lignes](/fr/admin/people/row-scopes/).
L’[exemple pas à pas](#exemple-pas-à-pas-ses-projets-via-les-équipes)
ci-dessous montre les deux moitiés ensemble.
:::

## Quand l’utiliser

- Un rôle ne peut voir ou modifier que ses propres lignes.
- Plusieurs rôles partagent une même règle de lignes, et vous ne voulez pas
  la répéter.
- Un lecteur a besoin d’un sous-ensemble enregistré via l’API, par exemple
  « projets actifs ».

## Avant de commencer

- **Côté auteur :** vous modifiez la définition du doctype pour déclarer
  les périmètres.
- **Côté admin :** un administrateur modifie le rôle pour les attacher.
  Cette page reste du côté auteur ; les règles d’application se trouvent
  sur [la page admin](/fr/admin/people/row-scopes/).

## Déclarer les périmètres

Ajoutez une table `scopes` à la définition du doctype. Chaque entrée porte
une description et un filtre `where`. Le doctype Company de Brightwater en
déclare un :

```yaml
# définition de clients.Company
scopes:
  my_clients:
    description: "Companies whose account manager is the caller."
    where:
      account_manager: "$self"
```

Les valeurs de `where` suivent une seule grammaire :

| Valeur | Correspondance |
| --- | --- |
| `"active"` | La valeur stockée exacte. |
| `"$self"` | L’id du compte appelant. Fonctionne sur un champ référence comme sur un champ chaîne simple qui stocke un id de compte. |
| `"$null"` | Les lignes où le champ est absent ou nul. Correspondance en égalité seulement. |
| `"$my_teams"` | Les valeurs d’un ensemble de contexte que le domaine déclare, résolues à chaque requête. Un ensemble vide ou non résoluble ne retient aucune ligne. |
| `"$organizational_unit"` | Le chemin d’unité organisationnelle du compte appelant. |

Un nom de champ peut porter un opérateur, comme les filtres de liste :
`priority__gte`, `title__match`, `price__between`. Un nom nu signifie
égalité. Un champ n’accepte que les opérateurs que ses capacités `filters`
déclarées permettent. Deux clés réservées lisent les colonnes système :
`$parent_id` (le lien parent) et `$doc_id` (l’id de la ligne), toutes deux
en égalité ou non-égalité seulement.

Facet valide la déclaration quand vous enregistrez le doctype : chaque
champ doit exister, et tout `$name` autre que `$self`, `$null` et
`$organizational_unit` doit nommer un ensemble de contexte que le domaine
déclare.

## Ensembles de contexte

Certaines règles lisent d’autres doctypes : « les projets de mes équipes »
suppose d’abord les adhésions aux équipes. Un **ensemble de contexte** est
une requête enregistrée que le domaine déclare — sur le document du
domaine, pas sur le doctype — et qui se résout en une liste de valeurs à
chaque requête :

```yaml
# le document du domaine, sous content
context_sets:
  my_teams:
    from: TeamMember     # un doctype du même domaine
    where:
      account: "$self"   # les lignes d’adhésion de l’appelant
    select: "$parent_id" # le champ à collecter ; $parent_id lit l’équipe parente
```

`from` nomme le doctype à interroger, `where` filtre ses lignes, et
`select` nomme le champ à collecter dans l’ensemble. Les deux acceptent
`$self`, `$parent_id`, `$doc_id` et d’autres ensembles de contexte : un
ensemble peut donc s’appuyer sur un autre. Un périmètre utilise ensuite
l’ensemble par son nom :

```yaml
# définition de projects.Project
scopes:
  team_projects:
    description: "Projects of the caller's teams"
    where:
      team: "$my_teams"
```

`$my_teams` n’est pas un jeton intégré — tout `$name` qui n’est pas l’une
des trois valeurs réservées se résout comme un ensemble de contexte. Le
même nom relie les deux déclarations.

## Attacher les périmètres à un rôle

Un administrateur ouvre le rôle, trouve le doctype et règle le périmètre
d’une action. La liste déroulante propose **Tout** plus chaque périmètre
déclaré sur le doctype. Plusieurs périmètres sur une même ligne se
combinent en OU : la permission atteint les lignes qui répondent à l’un
d’eux. La ligne de permission stockée ressemble à ceci :

```json
{ "action": "read", "on": "clients.Company", "scope": ["$my_clients"] }
```

Une ligne sans périmètre atteint toutes les lignes. La façon dont le
contrôleur applique l’alias à la liste, à la lecture et à l’écriture fait
l’objet de la page admin — voir
[Les périmètres de lignes](/fr/admin/people/row-scopes/).

## Resserrer une liste à la demande

N’importe quel lecteur peut passer un périmètre déclaré en paramètre sur
la route de liste. Il ne fait que resserrer ce que l’appelant peut déjà
voir :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/clients/Company?scope=my_clients"
```

Un nom inconnu répond `422` avec `Unknown scope`.

## Exemple

Le parcours Brightwater complet, en direct sur l’instance d’exemple :

1. L’auteur déclare `my_clients` sur `clients.Company`, comme ci-dessus.
2. Le rôle *Sales* porte la ligne de lecture montrée ci-dessus.
3. Tom se connecte et liste les sociétés. Il voit les cinq siennes : Maison
   Lumière, Festival des Collines, Cabinet Moreau, Château de Vireloup,
   Mairie de Saint-Clair — et rien d’autre.
4. La même liste avec `?scope=my_clients` renvoie les mêmes cinq,
   resserrée à partir de ce qu’il peut déjà voir. Une lecture directe de la
   société d’un autre commercial répond `404`, exactement comme un
   document manquant.

## Dépannage

**Le sélecteur de périmètre du rôle ne propose que Tout.**

Le doctype ne déclare pas encore de périmètres, ou l’enregistrement de la
définition a échoué. Ajoutez la table `scopes` et revérifiez le doctype.

**Une liste avec périmètre ne renvoie rien.**

Le filtre ne retient aucune ligne. Vérifiez la forme de la valeur
stockée : un littéral doit égaler exactement la valeur stockée, tandis que
`"$self"` reconnaît aussi bien la forme référence qualifiée que l’id nu.
Pour une valeur d’ensemble de contexte, vérifiez que l’ensemble se résout
pour ce compte : un ensemble vide ne retient aucune ligne de la liste non
plus.

**L’API répond Unknown scope.**

Le nom du périmètre n’est pas déclaré sur ce doctype. Reprenez le nom
depuis la définition.

**Un changement de rôle reste sans effet.**

Les permissions s’appliquent à la requête suivante. Rechargez la liste et
vérifiez que le rôle a été enregistré sur le bon chemin de doctype, par
exemple `clients.Company`.

## Exemple pas à pas : ses projets via les équipes

Un chef de projet lit uniquement les projets de sa propre équipe. Les
projets appartiennent à une équipe, une équipe a des membres, et chaque
membre désigne un compte. Un ensemble de contexte et un périmètre nommé
expriment cela, et le rôle référence le périmètre par son alias. Cette
section porte les déclarations côté auteur ; la moitié admin — la ligne de
rôle et ce que le chef de projet voit — se trouve sur
[Les périmètres de lignes](/fr/admin/people/row-scopes/).

### Le modèle de documents

Deux relations portent la règle :

- **Team → TeamMember** est une composition. `Team` est la racine
  d’agrégat et `TeamMember` est son enfant (`member_of: Team`). Chaque
  ligne de membre porte une référence `account` vers `iam.Account`.
- **Project → Team** est une référence. `Project` porte une référence
  `team` vers `projects.Team`.

*Les deux relations de données et les deux déclarations qui les lisent.*

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

Un doctype `TeamMember` séparé est la bonne forme ici : l’appartenance est
une ligne avec sa propre vie (date d’entrée, rôle dans l’équipe), et un
même compte peut siéger dans plusieurs équipes. Un unique champ référence
`members` sur `Team` ferait aussi l’affaire pour une liste plate, mais un
doctype enfant donne à chaque appartenance ses propres champs et son
propre journal d’audit.

```json
{ "domain": "projects", "doctype": "Team", "aggregate_root": true,
  "fields": { "name": { "type": "string", "required": true } },
  "children": { "members": { "doctype": "TeamMember", "collection": true } } }
```

```json
{ "domain": "projects", "doctype": "TeamMember", "member_of": "Team",
  "fields": { "account": { "type": "reference", "doctype": "iam.Account", "required": true } } }
```

```json
{ "domain": "projects", "doctype": "Project", "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true },
    "team": { "type": "reference", "doctype": "projects.Team", "filters": ["equality"] }
  } }
```

Voir [Composition parent/enfant](/fr/build/model/relations/parent-child/)
pour la paire `children`/`member_of`, et
[Relier des documents entre eux](/fr/build/model/relations/references-links/)
pour les champs référence.

### Les deux déclarations

Déclarez `my_teams` sur le document du domaine `projects`, et
`team_projects` sur `projects.Project` — les deux sont montrés dans
[Ensembles de contexte](#ensembles-de-contexte) ci-dessus. L’ensemble se
résout, à chaque requête, en les ids des équipes auxquelles l’appelant
appartient ; le périmètre retient les projets dont `team` figure dans cet
ensemble.

L’administrateur règle ensuite la ligne de lecture sur le rôle — le pas à
pas complet se trouve sur la page admin.

## Voir aussi

- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — attachez un périmètre à un rôle et voyez comment Facet l’applique.
- [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) — la grammaire complète des permissions.
- [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/) — comment rôles et permissions se relient.
- [Scripts de cycle de vie et garde-fous](/fr/build/model/behaviour/scripts-and-guards/) — surveillez les écritures comme vous filtrez les lectures.
