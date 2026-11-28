---
title: Visibilité des champs par étiquettes
description: "Étiquetez les champs sensibles pour que seuls les rôles choisis les lisent — à l’écran, dans l’API et dans le journal d’audit."
type: how-to
audience: [admin, author]
features: [RBC-04, AUD-03]
verified_at: eee55a2
sidebar:
  order: 5
---

Lucía dirige l’entrepôt de Brightwater. Elle lit des articles toute la
journée — il lui faut les noms, les catégories, les numéros de série. Ce
qu’il ne lui faut pas, c’est ce que chaque article a coûté. Le champ
`purchase_price` porte l’étiquette `finance`, son rôle *Warehouse* ne la
détient pas, et le champ est absent de tout ce qu’elle voit. Pas grisé, pas
à zéro — absent, dans l’application comme dans l’API.

Une **étiquette de champ** est une étiquette de sensibilité sur un champ. Un
rôle déclare quelles étiquettes il peut voir dans sa liste `visible_tags`.
Facet cache tout autre champ en lecture, refuse d’écrire dans les champs
cachés, et retire leurs valeurs du journal d’audit. La règle refuse par
défaut : une étiquette qu’aucun rôle n’accorde cache le champ à tout le
monde.

## Quand l’utiliser

- Un champ porte des données que seuls certains rôles peuvent voir, par
  exemple un salaire.
- Vous voulez une règle de visibilité unique que chaque surface applique
  pareil.
- Vous avez besoin du même masquage dans le journal d’audit, pas seulement
  dans les lectures en direct.

## Avant de commencer

- **Les définitions de champs.** Vous les modifiez — voir
  [Concevoir un doctype](/fr/build/model/data/design-doctypes/).
- **Le contenu des rôles.** Vous le modifiez — voir
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).

## Étapes

### 1. Étiqueter le champ

```yaml
# définition equipment.Item (exemple Brightwater)
fields:
  purchase_price:
    type: money
    currency: EUR
    tags: ["finance"]
```

Un champ sans `tags` porte l’étiquette `default`.

### 2. Accorder l’étiquette sur un rôle

```json
{
  "name": "manager",
  "visible_tags": ["default", "finance"]
}
```

Un rôle qui ne doit pas voir le champ garde les `visible_tags` par défaut de
`["default"]`. Chez Brightwater, `manager` liste `finance` ; `sales` et
`warehouse` non.

### 3. Vérifier ce que voit chaque rôle

Nadia lit un article avec le rôle *Manager* :

```json
{"name": "Festival tent 5x5", "purchase_price": {"value": "4800.00", "currency": "EUR"}, "status": "available"}
```

Tom lit le même article avec le rôle *Sales* :

```json
{"name": "Festival tent 5x5", "status": "available"}
```

Il n’y a pas de clé `purchase_price` dans la réponse de Tom, pas un null.

| Appelant           | `visible_tags`            | Lit `purchase_price`                    |
| ------------------ | ------------------------- | ---------------------------------------- |
| Nadia · manager    | `["default", "finance"]`  | oui, avec sa valeur                      |
| Tom · sales        | `["default"]`             | le champ est absent de la réponse        |
| Lucía · warehouse  | `["default"]`             | le champ est absent de la réponse        |

## Explication

### La règle de visibilité

Un champ est visible quand chacune de ses étiquettes se trouve dans les
`visible_tags` du rôle. La liste joker `["*"]` voit chaque champ. Tout le
reste est en refus par défaut.

### Le masquage en lecture

Facet omet les champs invisibles à chaque niveau d’imbrication : propriétés
d’objet, éléments de tableau, et valeurs de dictionnaire. Un parent
invisible cache tout son sous-arbre. Les clés de contenu que la définition
ne connaît pas sont omises aussi, pour chaque principal réel.

### Les garde-fous d’écriture

- Une écriture dans un champ invisible est refusée avec `403`. L’erreur nomme
  le chemin de contenu. Un `null` explicite compte comme une écriture.
- Le garde-fou tourne sur le corps brut soumis, avant la validation de
  format. Un appelant qui ne peut pas voir un champ n’apprend jamais son
  contrat de type par un `422`.
- Un garde-fou de transition compare l’état avant et après l’écriture. Il
  ramène les membres dans les valeurs d’objet, les clés de dictionnaire, et
  les marqueurs secrets au champ qui les possède. Un changement qui
  atterrit dans un champ invisible est refusé.
- Le travail de cycle de vie, lui, remplit toujours les champs invisibles :
  défauts, champs calculés, hooks.

### Le caviardage dans l’audit

Le journal des mutations stocke les valeurs réelles. Facet retire les
valeurs invisibles par principal appelant quand il lit le journal. La
réponse liste les chemins de contenu retirés dans un bloc de métadonnées
`redacted`. Chaque entrée est un tableau de segments de chemin — la même
forme que les chemins de diff.

| Forme de la ligne                                                        | Ce que voit l’appelant                                                       |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| Ligne de contenu complète (create, instantané, tombstone de suppression) | valeurs invisibles retirées à chaque niveau ; un parent visible garde sa partie visible |
| Diff de mise à jour                                                      | une entrée `set` sur un chemin invisible garde son chemin mais perd sa valeur |
| Définition manquante                                                     | toutes les valeurs retirées — le refus par défaut                              |

Aucun marqueur n’entre dans le contenu stocké. La liste `redacted` est la
seule trace du retrait.

:::tip
Le retour arrière vérifie la visibilité sur la transition réelle, pas sur
l’entrée du journal. Un retour arrière qui rembobinerait une valeur dans un
champ invisible répond `403` — voir
[Revenir en arrière](/fr/admin/history/roll-back/).
:::

### Les étiquettes ne sont pas des secrets

Les étiquettes cachent un champ par rôle. Deux genres de champs se cachent à
tout le monde :

- Un champ `secret` ne stocke jamais sa valeur dans un document ni dans le
  journal.
- Un champ `write_only` accepte une entrée et ne revient jamais dans les
  lectures.

Voir [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/).

## Dépannage

### Un champ manque dans une réponse

Vérifiez les `tags` du champ et les `visible_tags` du rôle. Une étiquette
que le rôle ne liste pas cache le champ.

### Une écriture répond `403` pour un champ que vous ne vouliez pas toucher

Un `null` explicite dans le corps compte comme une écriture. Omettez la clé
à la place.

### Une ligne d’historique n’affiche pas de valeur

Du caviardage pour votre rôle. Un rôle avec l’étiquette lit la valeur dans
la même ligne.

### Un hook remplit un champ invisible et fonctionne

Le travail de cycle de vie est de confiance. Seules les écritures de
l’appelant et les transitions pilotées par l’appelant sont gardées.

## Voir aussi

- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — où se
  trouve `visible_tags`.
- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — resserrer les
  lignes comme les étiquettes resserrent les champs.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — où apparaît le bloc
  `redacted`.
- [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/) —
  caché à tout le monde, pas par rôle.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Les rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/)
