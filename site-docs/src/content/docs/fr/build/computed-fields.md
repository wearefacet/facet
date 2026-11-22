---
title: Champs calculés
description: Dérivez la valeur d’un champ avec une fonction de calcul Lua, relancée à chaque changement de ses entrées.
audience: [author]
features: [DOM-09]
sidebar:
  order: 12
verified_at: fd345fe3
---

Un champ calculé garde une valeur à jour sans qu’aucun utilisateur ne l’écrive. Vous déclarez le champ, vous nommez une fonction, et vous listez les entrées qui déclenchent une réexécution. Facet exécute la fonction à la création, la relance à chaque changement d’une entrée listée, et stocke le résultat dans le document.

## Quand l’utiliser

Ajoutez un champ calculé pour une valeur que les utilisateurs devraient sinon tenir à jour à la main, et se tromperaient : un total sur des lignes de commande, une ancienneté en jours, un numéro composé de plusieurs parties. Un champ calculé ne vient jamais de la saisie utilisateur. Facet refuse toute valeur fournie pour lui.

## Avant de commencer

- **Trois éléments.** Un champ calculé porte le type `data`, un nom dans `compute`, et une liste `compute_when`.
- **Une fonction dans le script.** La fonction doit exister dans le script du doctype. Facet le vérifie quand vous enregistrez le doctype.
- **Lecture seule par conception.** Le calcul peut lire des documents, mais jamais en écrire. Pour modifier d’autres documents, utilisez une action ou un hook de domaine.

## Étapes

### 1. Déclarer le champ

```json
"total": {
  "type": "data",
  "compute": "total",
  "compute_when": ["qty", "unit_price"]
}
```

La valeur de `compute` nomme la fonction exportée. Facet appelle ainsi `compute_total`. Chaque entrée de `compute_when` est soit un champ du doctype, soit le nom d’une relation enfant. Facet exécute tous les champs calculés à la création. À la mise à jour, seuls ceux dont les déclencheurs recoupent les champs modifiés sont relancés.

### 2. Écrire la fonction

Renvoyez la valeur. La fonction suit la structure de module standard, comme dans tout script de doctype.

```lua
local export = {}

function export.compute_total(ctx)
  return (ctx.root.qty or 0) * (ctx.root.unit_price or 0)
end

return export
```

Renvoyer `nil` vide le champ. Utilisez cela pour une valeur conditionnelle, par exemple une ancienneté qui reste vide tant que la date d’embauche n’existe pas.

### 3. Calculer à partir des enfants

Quand `compute_when` nomme une relation enfant, Facet vous fournit les lignes enfants à jour dans `ctx.children`, et relance le champ du parent dès qu’un enfant de cette relation change.

```lua
local export = {}

function export.compute_order_total(ctx)
  local total = 0
  for _, line in ipairs((ctx.children or {}).lines or {}) do
    total = total + (line.qty or 0) * (line.price or 0)
  end
  return total
end

return export
```

Le champ déclare `compute_when: ["lines"]`, où `lines` est l’entrée `children` du doctype.

## Exemple

La définition ci-dessous déclare deux champs d’entrée et le total calculé.

```json
{
  "domain": "projects",
  "doctype": "WorkPackage",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "qty": { "type": "integer", "min": 0 },
    "unit_price": { "type": "integer", "min": 0 },
    "total": { "type": "data", "compute": "total", "compute_when": ["qty", "unit_price"] }
  }
}
```

Une création avec `{"qty": 3, "unit_price": 250}` stocke `total: 750`. Un passage de `qty` à `4` relance la fonction dans la même écriture et stocke `total: 1000`. Quand le déclencheur est une relation enfant, la réexécution écrit la valeur du parent comme une entrée d’historique distincte.

:::note
Le nom d’affichage et le texte de recherche d’un doctype se dérivent aussi, mais par des modèles Jinja2, pas par Lua. Voir [Noms d’affichage et texte de recherche](/fr/build/display-names-search-text/).
:::

## Dépannage

### Le champ reste vide

Soit la fonction a renvoyé `nil`, soit aucun déclencheur n’a été activé. Vérifiez que chaque entrée de `compute_when` est un nom de champ ou une relation enfant du même doctype. Facet refuse la définition dans le cas contraire.

### La valeur reste obsolète après un changement d’enfant

La liste `compute_when` doit nommer la relation enfant, pas un champ de l’enfant. Avec `["lines"]`, chaque changement sous `lines` relance le champ du parent.

### L’écriture répond `422` avec `Computed fields failed`

La fonction a levé une erreur. Lisez le message, corrigez la fonction, et enregistrez le doctype. Un échec déclenche un retour arrière de toute l’écriture : aucune valeur obsolète n’est stockée.

### Un utilisateur a tenté de remplir le champ

Par conception, les champs calculés refusent la saisie utilisateur. Retirez le champ du formulaire, ou faites-en un champ normal sans calcul.

## Voir aussi

- [API Lua (référence)](/fr/reference/lua-api/) — ce qu’une fonction de calcul peut appeler, et ses limites.
- [Le journal des mutations](/fr/concepts/mutation-log/) — comment une réexécution atterrit dans l’historique.
- [Noms d’affichage et texte de recherche](/fr/build/display-names-search-text/) — dériver noms et texte de recherche avec des modèles Jinja2.
