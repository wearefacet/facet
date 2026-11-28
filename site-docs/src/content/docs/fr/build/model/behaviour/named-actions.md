---
type: how-to
title: Ajouter des actions à un doctype
description: Ajoutez à un doctype des actions nommées, avec des arguments typés et une implémentation Lua.
audience: [author]
features: [DOM-07]
sidebar:
  order: 0
verified_at: eee55a2
---

Une équipe d’entrepôt doit passer un article défectueux en réparation d’un clic, pas en modifiant un champ de statut à la main. Une **action nommée** est une opération qui porte un nom, comme `confirm` ou `send_to_repair`. L’utilisateur la lance depuis le menu de la page du document, Facet vérifie les arguments typés, et une fonction Lua dans le script du doctype fait le travail. Le corps de fonction demande du Lua — une introduction de dix lignes suffit, et la surface complète se trouve dans la [Référence de l’API Lua](/fr/reference/lua-api/).

## Quand l’utiliser

Ajoutez une action quand un changement demande plus qu’une modification : une règle d’état, plusieurs champs déplacés ensemble, ou une valeur dérivée des arguments. Si la règle ne vérifie qu’un seul champ, une contrainte de champ ou un garde-fou de cycle de vie est plus simple — voir [Scripts et garde-fous](/fr/build/model/behaviour/scripts-and-guards/).

## Avant de commencer

- **Un script.** Un doctype qui déclare des actions doit porter un script, et le [script](/fr/build/model/behaviour/scripts-and-guards/) doit définir une fonction par action.
- **Une permission.** Les utilisateurs ont besoin d’une permission dont le nom d’action égale la clé de l’action, par exemple `send_to_repair` sur `equipment.Item`.
- **Un nom libre.** Huit noms sont réservés au cycle de vie : `validate`, `create`, `update`, `delete`, `migrate`, `snapshot`, `history`, `rollback`. Une action ne peut pas en prendre un.

## Déclarer l’action

Ajoutez l’action à la table `actions` du doctype :

```yaml
# equipment.Item definition
actions:
  send_to_repair:
    args: {}
```

Une définition d’action porte ces clés :

| Clé | Utilité |
| --- | --- |
| `args` | Des arguments typés. Facet vérifie `type`, `required`, `default`, `min`/`max`, une liste fermée `values` et `collection` avant que le script ne s’exécute. |
| `states` | Les valeurs de champs que le document doit porter avant que l’action soit proposée. Une action sans `states` est toujours proposée. |
| `description` | Le texte que l’éditeur d’actions affiche. |
| `event_name` | L’événement que l’action émet. Par défaut, c’est la forme au passé de la clé de l’action. |

Chaque argument porte un type. Un argument `required` répond `422` quand il manque ; `min`/`max` bornent les nombres (et les longueurs de chaînes) ; `values` ferme le choix à une liste ; `collection: true` fait de l’argument un tableau et vérifie chaque élément. Un argument de référence arrive dans le script déjà qualifié, comme `equipment.Item.<id>`.

La barrière `states` garde le menu honnête. Pour proposer **Envoyer en réparation** seulement quand l’article n’est pas déjà en réparation :

```yaml
actions:
  send_to_repair:
    states:
      status: [available, out]
    args: {}
```

Un document en dehors de ces états répond `422` avant que le script ne s’exécute, et la page du document cache l’entrée de menu selon la même règle.

## Implémenter la fonction

Le script exporte une fonction par action. Il reçoit le contexte `ctx` et les arguments vérifiés `args`, et il modifie le document en écrivant dans `ctx.root`. Le script de l’article Brightwater est complet :

```lua
-- equipment.Item.lua
local export = {}

-- Action nommée : envoyer l’article en réparation.
-- Seul un article qui n’est pas déjà en réparation peut y passer.
function export.send_to_repair(ctx, args)
    if ctx.root.status == "in_repair" then
        ctx.error("Item is already in repair")
        return
    end
    ctx.root.status = "in_repair"
end

return export
```

`ctx.error` recueille un refus : l’écriture échoue avec `422` et porte votre message.

## Attribuer la permission

Ajoutez à un rôle une ligne de permission qui porte le nom de l’action :

```json
{ "action": "send_to_repair", "on": "equipment.Item" }
```

Sans la ligne, l’entrée de menu reste cachée et un appel direct répond `403`. Qui détient quelle ligne est le travail d’un administrateur — voir [Rôles et permissions](/fr/admin/people/roles-and-permissions/).

## Exécuter l’action

Dans l’application, ouvrez un document et choisissez l’action dans son menu. Facet vérifie les arguments, exécute le script et affiche le résultat. Le même appel fonctionne via l’API :

```sh
curl -k -X POST "$(facet-cli host)/Api/equipment/Item/EQ-2026-0001/send_to_repair" \
  -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{}'
```

`-k` ignore la vérification du certificat de l’adresse de développement locale. L’article affiche alors **En réparation** partout. Facet enregistre une entrée d’historique avec les champs que l’action a modifiés.

Les événements voyagent avec les actions. La réservation Brightwater déclare ses deux actions avec des noms d’événements explicites, et le hook du domaine equipment écoute exactement ces noms :

```yaml
# rentals.Booking definition
actions:
  confirm:
    args: {}
    event_name: booking_confirmed
  mark_returned:
    args: {}
    event_name: booking_returned
```

Sans surcharge, Facet dérive le nom de l’événement à partir de la clé de l’action. Voir [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) pour le hook qui les consomme.

## Dépannage

**L’entrée de menu n’apparaît pas.**

L’état du document ne passe pas la barrière `states`, ou votre rôle n’a pas la permission de l’action.

**L’appel répond `422` avec une erreur d’argument.**

Un argument manque, est hors limites, ou ne figure pas dans une liste fermée `values`. Le message nomme l’argument.

**L’appel répond `422` avec une erreur de script.**

La fonction Lua a levé une erreur qu’elle n’a pas interceptée. Le message porte le numéro de ligne dans votre script. Corrigez le script et enregistrez le doctype ; le cache des définitions se met à jour une à deux secondes plus tard.

**L’action s’est exécutée mais rien n’a changé.**

La fonction est revenue sans modifier `ctx.root`. Facet n’enregistre aucune entrée d’historique quand une action ne change rien.

## Voir aussi

- [API Lua](/fr/reference/lua-api/) — toute la surface de script.
- [Scripts et garde-fous](/fr/build/model/behaviour/scripts-and-guards/) — protéger les écritures avec des hooks Lua.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — comment une action arrive dans l’historique.
