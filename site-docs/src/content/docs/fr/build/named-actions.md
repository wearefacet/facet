---
title: Actions nommées
description: Ajoutez des actions nommées avec des arguments typés et une implémentation Lua à un doctype.
audience: [author]
features: [DOM-07]
sidebar:
  order: 10
verified_at: fd345fe3
---

Une action nommée est une opération qui porte un nom, comme `promote` ou
`release`. L’utilisateur la lance depuis le menu de la page détail, Facet
vérifie les arguments typés, puis une fonction Lua du script du doctype fait
le travail. L’action laisse dans l’historique les changements qu’elle a
produits, à côté des modifications ordinaires.

## Quand l’utiliser

Ajoutez une action quand un changement demande plus qu’une modification :
une règle d’état, plusieurs champs déplacés ensemble, ou une valeur
calculée à partir des arguments. Si la règle ne vérifie qu’un seul champ,
un `pattern` ou un garde-fou du cycle de vie est plus simple (voir
[Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/)).

## Avant de commencer

- **Un script.** Un doctype qui déclare des actions doit porter un script,
  et le script doit définir une fonction par action.
- **Une permission.** Les utilisateurs ont besoin d’une permission dont le
  nom d’action reprend la clé de l’action, par exemple `promote` sur
  `hr.Employee`.
- **Un nom libre.** `validate`, `create` et `update` sont des noms
  réservés ; ils appartiennent au cycle de vie.

## Étapes

### 1. Déclarer l’action

```json
"actions": {
  "release": {
    "description": "Release the order to production",
    "states": { "status": ["approved"] },
    "args": {
      "note": { "type": "string", "required": true, "max": 200 }
    }
  }
}
```

| Clé | Utilité |
| --- | --- |
| `args` | Des arguments typés. Facet vérifie le type, `required`, `min`/`max`, `default` et une liste fermée `values` avant que le script ne s’exécute. |
| `states` | Les valeurs de champs que le document doit porter pour que l’action soit proposée. Une action sans `states` est toujours proposée. |
| `description` | Le texte que l’éditeur d’actions affiche. |

### 2. Implémenter la fonction

Le script exporte une fonction par action. Il reçoit le contexte `ctx` et
les arguments vérifiés `args`, et il modifie le document en écrivant dans
`ctx.root`.

### 3. Ajouter la permission

Ajoutez à un rôle une ligne de permission qui porte le nom de l’action :

```json
{ "action": "release", "on": "projects.Order" }
```

Sans cette ligne, l’entrée de menu reste cachée et un appel direct répond
`403`.

### 4. Exécuter l’action

Dans l’application, ouvrez un document et choisissez l’action dans son
menu. Facet vérifie les arguments, exécute le script et affiche le
résultat.

## Exemple

Le script complet ci-dessous implémente `release`. Il revérifie la règle
d’état, positionne trois champs et enregistre l’heure.

```lua
local export = {}

function export.release(ctx, args)
  if ctx.root.status ~= "approved" then
    ctx.error("Only approved orders can be released")
    return
  end
  ctx.root.status = "released"
  ctx.root.released_at = ctx.now
  ctx.root.release_note = args.note
end

return export
```

L’appel exécute l’action sur un document :

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Order/01HQ2F5WX8K4M3PZC6NRB9TJVA/release" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"note": "Budget confirmed"}'
```

`-k` ignore la vérification du certificat de l’adresse de développement
locale. Facet enregistre une entrée d’historique avec les champs que
l’action a modifiés.

## Dépannage

### L’entrée de menu n’apparaît pas

L’état du document ne passe pas la barrière `states`, ou votre rôle n’a
pas la permission de l’action.

### L’appel répond `422` avec une erreur d’argument

Un argument manque, est hors limites, ou ne figure pas dans une liste
fermée `values`. Le message nomme l’argument.

### L’appel répond `422` avec une erreur de script

La fonction Lua a levé une erreur qu’elle n’a pas interceptée. Le message
porte le numéro de ligne dans votre script. Corrigez le script et
enregistrez le doctype ; le cache de définition se met à jour une à deux
secondes plus tard.

### L’action s’est exécutée mais rien n’a changé

La fonction est revenue sans modifier `ctx.root`. Facet n’enregistre
aucune entrée d’historique quand une action ne change rien.

## Voir aussi

- [Référence de l’API Lua](/fr/reference/lua-api/) — toute la surface de
  script.
- [Le journal des mutations](/fr/concepts/mutation-log/) — comment une
  action atterrit dans l’historique.
- [Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/) —
  protéger les écritures avec des hooks Lua.
