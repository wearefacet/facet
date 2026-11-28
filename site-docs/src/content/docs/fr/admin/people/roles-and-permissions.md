---
title: Rôles et lignes de permission
description: Écrivez un rôle en lignes de permission, réglez son niveau, ses étiquettes et ses canaux, et connaissez le garde-fou qui borne chaque écriture de rôle.
type: how-to
audience: [admin, author]
features: [RBC-01, RBC-07]
verified_at: eee55a2
sidebar:
  order: 2
---

Tom rejoint Brightwater comme commercial. Que peut-il lire, modifier et
créer ? La réponse tient dans un seul document : un **rôle**. Un rôle
rassemble des lignes de permission, un niveau, des étiquettes de visibilité
de champs, et les canaux de connectivité. Vous écrivez les rôles ici, et
chaque contrôle de Facet les lit — sur les écrans, dans l’API, dans les apps
et dans l’assistant.

Un rôle est un document du doctype `iam.Roles`. Son id prend la forme
qualifiée `iam.Roles.<name>`, par exemple `iam.Roles.editor`.

## Quand l’utiliser

- Vous écrivez ou modifiez un rôle et devez en énoncer la portée exactement.
- Vous devez savoir pourquoi une écriture de rôle a répondu `403`.
- Vous auditez quels rôles portent les actions d’opérateur sensibles.

## Avant de commencer

- **La bonne page.** Ouvrez **Configurer → Accès → Rôles**. La page de liste
  héberge l’éditeur d’octrois ; chaque rôle a aussi une page détail avec les
  onglets Détails, Membres et Octrois.

<!-- screenshot: configure-roles-detail -->
- **Le modèle.** Lisez
  [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/)
  pour le concept, et
  [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)
  pour savoir où s’exerce le contrôle.

## Le document rôle

| Champ | Contenu |
| --- | --- |
| `name` | Le nom de rôle unique. Il forme l’id du document et est immuable. |
| `level` | Entier obligatoire de 0 à 100. Il ordonne les rôles par autorité. |
| `permissions` | Les lignes de permission. |
| `visible_tags` | Les étiquettes de champs que le rôle peut voir. Par défaut `["default"]` ; `["*"]` voit tout. |
| `connectivity` | Les canaux programmatiques, voir ci-dessous. |
| `description` | Du texte libre pour les humains. |

## La ligne de permission

Une ligne a quatre parties. Toutes sont facultatives sauf `action` et `on` :

| Partie | Contenu |
| --- | --- |
| `action` | `read`, `create`, `update`, `delete`, `*`, ou une action nommée. |
| `on` | Un chemin de doctype, par exemple `crm.Deal`, ou le joker `*.*`. |
| `scope` | Un tableau de périmètres de lignes nommés. Ils se combinent en OU. |
| `except` | Un tableau de chemins concrets soustraits de la portée. |

### `on` et correspondance par préfixe

Une ligne sur un chemin parent couvre aussi les enfants imbriqués. Une ligne
sur `crm.Project` correspond aussi à `crm.Project.Comment`. Le joker `*.*`
correspond à chaque doctype de chaque domaine. Les rôles admin créés par
l’initialisation le portent.

### `scope`

La forme tableau est obligatoire sur chaque chemin d’écriture. Chaque entrée
nomme un périmètre déclaré sur le doctype cible. Les alias se combinent en
OU : la ligne atteint les lignes qui répondent à l’un des alias. Omettre
`scope` atteint toutes les lignes. Voir
[Les périmètres de lignes](/fr/admin/people/row-scopes/) pour la déclaration
et les alias.

### `except`

`except` resserre une seule ligne. Les entrées sont des chemins
`domain.Doctype` concrets ; pas de jokers. Une entrée fait de la
correspondance par préfixe comme `on` : une entrée sur `core.DocType` exclut
aussi `core.DocType.Comment`. C’est de l’arithmétique de chemins, pas un
système de refus : elle n’accorde rien, et elle ne touche que la ligne qui
la porte.

### Exemples

Chaque exemple est une ligne complète, avec l’effet énoncé.

```json
{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}
```

Cette ligne laisse un membre lire les projets qu’il possède et les projets
sans propriétaire.

```json
{"action": "create", "on": "crm.Deal"}
```

Cette ligne laisse un membre créer une affaire partout dans `crm.Deal`.

```json
{"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}
```

Cette ligne laisse un membre modifier chaque document sauf les deux surfaces
de définition : la forme des domaines et des doctypes reste en lecture seule
pour lui.

```json
{"action": "read", "on": "fin.Invoice", "scope": ["$mine"]}
```

Cette ligne laisse un membre lire uniquement les factures qu’il possède.

```json
{"action": "read", "on": "hr"}
```

Un chemin à un seul segment, un nom de domaine en minuscules, couvre tout le
domaine. Cette ligne laisse un membre lire chaque doctype de `hr`.

## Les canaux de connectivité

`connectivity` est un tableau tiré d’un vocabulaire fermé : `mcp`,
`webhook`, `api` et `assistant`. Il décide quelles portes programmatiques le
rôle peut ouvrir du tout. Une liste vide fait un rôle réservé au navigateur.
Les sessions navigateur et les tokens d’application ne dépendent jamais du
champ.

- `api` — le rôle peut porter des clés d’API. Voir
  [Accès machine : clés d’API](/fr/admin/apps-access/api-keys/).
- `mcp` — des agents peuvent se connecter par la surface MCP (Model Context
  Protocol) avec ce rôle.
- `webhook` — le rôle peut créer et recevoir des webhooks. Voir
  [Webhooks sortants](/fr/build/model/automation/webhooks/).
- `assistant` — le rôle peut ouvrir l’assistant IA (intelligence
  artificielle). Voir [Gouverner l’assistant](/fr/admin/assistant/govern/).

Chaque barrière de canal lit le rôle en direct. Un canal retiré s’applique à
la requête suivante.

## Les actions nommées

En plus des quatre actions CRUD, une ligne peut accorder une action nommée.
Les noms d’actions qui barrent des routes fixes valent d’être connus :

| Action | Sur | Barre |
| --- | --- | --- |
| `provision_credentials` | `iam.Account` | Mots de passe temporaires, liens d’invitation, lectures des états d’identifiants. |
| `mfa_disable` | `iam.Account` | `POST /Api/iam/mfa/disable`, la récupération par l’administrateur. |
| `publish_artifact` | le doctype cible | Fabriquer des liens de fichiers permanents sur ce doctype. |
| `revoke` | `*.*` | Révoquer n’importe quel lien de fichier. |
| `download` | `*.*` | Télécharger n’importe quel fichier comme opérateur. |
| `purge` | `*.*` | Supprimer définitivement n’importe quel fichier, la suppression auditée. |

:::caution
Un rôle qu’une application externe peut élire ne doit pas porter
`provision_credentials`, `mfa_disable`, `revoke`, `download` ni `purge`.
Gardez ces cinq actions sur les seuls rôles d’opérateurs humains. Voir
[La portée des apps (attributions)](/fr/admin/apps-access/app-grants/).
:::

## Le garde-fou d’autorité des rôles

Chaque écriture contrôlée par l’appelant sur `iam.Account` et `iam.Roles`
passe par un seul garde-fou. Il couvre create, update, delete, les actions
nommées, et les transitions de retour arrière. Un refus répond `403`. Le
niveau de l’appelant vient de l’unique rôle élu de la requête, jamais du
rôle le plus élevé que l’appelant porte.

| Vérification | Règle |
| --- | --- |
| Affectation | Chaque rôle du tableau `roles` final doit exister, être vivant, et se situer au niveau de l’appelant ou en dessous. `default_role` doit en faire partie. |
| Même niveau | Un appelant peut affecter un rôle de son propre niveau, même quand ce rôle porte des pouvoirs qui lui manquent. |
| Protection de la cible | Aucune écriture sur un compte ou un rôle dont le niveau courant dépasse celui de l’appelant, pas même pour l’abaisser. |
| Écriture du rôle | Le niveau résultant ne doit pas dépasser celui de l’appelant. Chaque nouvelle ligne doit découler du rôle précédent ou du rôle de l’appelant. Les nouvelles étiquettes visibles doivent rester dans l’union des deux. Les canaux de connectivité et le budget de l’assistant suivent la même inclusion. |

La règle d’inclusion borne un éditeur de rôles : un éditeur de niveau 30 ne
peut pas élargir un rôle de niveau 20 au-delà de ce que le contenu précédent
ou son propre rôle implique. Voir
[Affecter les rôles et l’élection](/fr/admin/people/assign-roles/)
pour le flux d’affectation.

## Les rôles créés par l’initialisation

| Id du rôle | Niveau | Portée |
| --- | --- | --- |
| `iam.Roles.admin` | 100 | `*` sur `*.*`, tous les canaux, toutes les étiquettes. |
| `iam.Roles.editor` | 30 | Lit et modifie le contenu partout ; les surfaces de définition et `core.SystemSettings` sont retranchées avec `except`. |
| `iam.Roles.viewer` | 20 | Lit partout, avec les mêmes retranchements. |
| `iam.Roles.comment_author` | 20 | Lecture, modification et suppression sur `core.Comment`, limitées à l’auteur par `$mine`. |
| `iam.Roles.attachment_owner` | 20 | Lecture, modification et suppression sur `core.Attachment`, limitées à la personne qui a déposé le fichier par `$mine`. |
| `iam.Roles.anonymous` | 0 | Sert les requêtes sans identifiant. Ses attributions de lecture forment la surface publique de l’API. Supprimez-le, et ces requêtes répondent `401`. |

Le retranchement de `core.SystemSettings` est le modèle à copier : les rôles
`editor` et `viewer` créés par l’initialisation soustraient le chemin de
leurs lignes générales avec `except: ["core.SystemSettings"]`, si bien que
les réglages d’exécution restent réservés aux administrateurs. Un rôle sur
mesure peut toujours recevoir le chemin explicitement.

Brightwater ajoute trois rôles au-dessus de ces créations : `manager`
(niveau 60, voit l’étiquette `finance`), `sales` (niveau 40, un périmètre de
lignes le resserre sur ses propres clients), et `warehouse` (niveau 40, sans
l’étiquette `finance`). Vous croisez les trois dans les pages suivantes.

## Le nom du rôle est immuable

L’id du document est `iam.Roles.<name>`, et les documents comptes
référencent cet id. Un renommage désynchroniserait l’id du nom ; le hook de
mise à jour refuse donc toute écriture qui porte `name` :

```json
{"error": "Script validation failed", "details": [{"message": "'name' is immutable after creation — the role id is iam.Roles.wp18a_renamed; recreate the role under the new name", "code": "script"}]}
```

Pour renommer, créez un nouveau rôle sous le nouveau nom, déplacez les
affectations, puis supprimez l’ancien. Le hook de suppression refuse tant
qu’un compte porte encore le rôle.

## Exemple

Créez un rôle de lecture régionale pour le domaine `fin` :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "regional_reader",
    "level": 10,
    "visible_tags": ["default"],
    "permissions": [
      {"action": "read", "on": "fin.Invoice"},
      {"action": "read", "on": "hr.Employee", "scope": ["$mine"]}
    ]
  }' \
  "$(facet-cli host)/Api/iam/Roles"
```

Le nouveau rôle lit chaque facture et laisse chaque membre lire sa propre
fiche employé. Il ne porte aucun canal ni aucune action d’opérateur.

## Dépannage

### L’écriture du rôle répond `403`

Vérifiez les quatre lignes du garde-fou ci-dessus. La cause la plus
fréquente est une nouvelle ligne de permission que le rôle propre de
l’appelant n’implique pas, ou une cible dont le niveau dépasse celui de
l’appelant.

### Une écriture avec un périmètre en chaîne répond `422 must be an array`

Les chemins d’écriture exigent la forme tableau. Remplacez
`"scope": "$mine"` par `"scope": ["$mine"]`.

### Le PATCH qui renomme un rôle répond `422`

Le nom est immuable. Recréez le rôle sous le nouveau nom.

### Un membre voit un champ que vous vouliez cacher

Vérifiez `visible_tags` sur son rôle — voir
[Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/).

## Voir aussi

- [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) —
  placer des rôles sur les comptes.
- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — resserrer une
  ligne sur des lignes précises.
- [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/) —
  resserrer ce qu’un rôle voit dans un document.
- [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/) — la
  page de concept du garde-fou.
- [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/) —
  la borne côté application.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
- [Syntaxe des lignes de permission](/fr/reference/permission-syntax/)
