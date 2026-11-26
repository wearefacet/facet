---
title: Visibilité des champs par étiquettes
description: "Masquez les champs sensibles par rôle en lecture, refusez d’y écrire, et caviardez-les dans le journal d’audit."
audience: [admin, author]
features: [RBC-04, AUD-03]
sidebar:
  order: 5
verified_at: fd345fe3
---

Un champ peut porter une ou plusieurs étiquettes de sensibilité. Un rôle
déclare quelles étiquettes il peut voir dans sa liste `visible_tags`. Facet
cache tout autre champ en lecture, refuse d’écrire dans les champs cachés,
et retire leurs valeurs du journal d’audit. La règle refuse par défaut : une
étiquette qu’aucun rôle n’accorde cache le champ à tout le monde.

## Quand l’utiliser

- Un champ porte des données que seuls certains rôles peuvent voir, par
  exemple un salaire.
- Vous voulez une règle de visibilité unique que chaque surface applique
  pareil.
- Vous avez besoin du même masquage dans le journal d’audit, pas seulement
  dans les lectures en direct.

## Avant de commencer

- **Les définitions de champs.** Vous les modifiez — voir
  [Concevoir des doctypes](/fr/build/model/data/design-doctypes/).
- **Le contenu des rôles.** Vous le modifiez — voir
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).

## Étapes

### 1. Étiqueter le champ

```yaml
# définition hr.Employee
fields:
  name:
    type: string
  salary:
    type: money
    currency: EUR
    tags: ["salary"]
```

Un champ sans `tags` porte l’étiquette `default`.

### 2. Accorder l’étiquette sur un rôle

```json
{
  "name": "hr_partner",
  "visible_tags": ["default", "salary"]
}
```

Un rôle qui ne doit pas voir le champ garde les `visible_tags` par défaut de
`["default"]`.

### 3. Vérifier ce que voit chaque rôle

| Appelant                                 | Lit `name` | Lit `salary`                          |
| ---------------------------------------- | ---------- | -------------------------------------- |
| `hr_partner` (`["default", "salary"]`)   | oui        | oui, avec sa valeur                    |
| `team_lead` (`["default"]`)              | oui        | le champ est absent de la réponse      |

## Explication

### La règle de visibilité

Un champ est visible quand chacune de ses étiquettes se trouve dans les
`visible_tags` du rôle. La liste joker `["*"]` voit chaque champ. Tout le
reste refuse par défaut.

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

| Forme de la ligne                                       | Ce que voit l’appelant                                                          |
| -------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Ligne de contenu complète (create, instantané, tombstone de suppression) | valeurs invisibles retirées à chaque niveau ; un parent visible garde sa partie visible |
| Diff de mise à jour                                      | une entrée `set` sur un chemin invisible garde son chemin mais perd sa valeur    |
| Définition manquante                                     | toutes les valeurs retirées — le refus par défaut                                |

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

## Exemple

Un enregistrement employé porte `name` et le champ `salary` étiqueté de
l’étape 1.

1. `hr_partner` lit l’employé. La réponse porte `name` et `salary` avec sa
   valeur.
2. `team_lead` lit le même employé. La réponse ne porte que `name`. Il n’y a
   pas de clé `salary`, pas un null.
3. `team_lead` envoie un patch qui met `salary` à `null`. Facet répond `403`
   et nomme le chemin : un null explicite est une écriture.
4. `team_lead` ouvre l’historique de l’employé. Les lignes du salaire
   s’affichent sans valeurs, et le bloc `redacted` nomme les chemins.
   `hr_partner` lit le même historique et voit les valeurs.

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
- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — resserrer les lignes
  comme les étiquettes resserrent les champs.
- [Auditer l’activité](/fr/admin/history/audit/) — où apparaît le bloc
  `redacted`.
- [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/) —
  caché à tout le monde, pas par rôle.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
