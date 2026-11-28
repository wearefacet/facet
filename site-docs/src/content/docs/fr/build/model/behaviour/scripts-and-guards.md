---
type: how-to
title: Scripts et garde-fous
description: Appliquez vos règles avec des hooks Lua sur chaque création, modification, suppression et action.
audience: [author]
features: [DOM-08]
sidebar:
  order: 1
verified_at: eee55a2
---

Une date interdite dans le futur, un responsable imposé depuis l’appelant, un enregistrement fermé aux modifications dans un état donné — un **script de cycle de vie** couvre des règles comme celles-ci. Il s’exécute dans chaque écriture d’un doctype : il peut vérifier le document et refuser l’écriture, ou remplir et corriger des champs avant que Facet ne les stocke. Cette page demande du Lua ; le motif de module de dix lignes suffit pour démarrer, et la surface complète des fonctions se trouve dans la [Référence de l’API Lua](/fr/reference/lua-api/). Le script fait partie de la définition du doctype, donc vos règles voyagent avec le modèle et s’appliquent sur chaque chemin — l’application, l’API et les agents.

## Quand l’utiliser

Ajoutez un script quand une règle dépasse ce que les contraintes de champ expriment : une date qui ne doit pas se trouver dans le futur, un responsable imposé depuis l’appelant, un enregistrement fermé aux modifications dans un état donné. Gardez les règles simples de format dans les contraintes de champ, et les droits sur les lignes dans les rôles.

## Avant de commencer

- **[Lua](/fr/reference/lua-api/).** Le script suit un seul motif de module : il définit des fonctions et les renvoie dans une table.
- **Un script qui compile.** Une erreur de syntaxe bloque l’enregistrement du doctype : Facet compile le script à l’enregistrement et signale la ligne.
- **Aucune valeur secrète.** Un script ne voit jamais les valeurs secrètes ; un champ `secret` ne porte ici que son marqueur.

## Les hooks

| Fonction | S’exécute | Peut |
| --- | --- | --- |
| `export.validate(ctx)` | Avant chaque create, update, delete et action | Vérifier et refuser avec `ctx.error` |
| `export.create(ctx)` | Une seule fois, sur create | Vérifier, refuser et modifier `ctx.root` |
| `export.update(ctx)` | À chaque update | Vérifier, refuser et modifier `ctx.root` |
| `export.delete(ctx)` | Sur delete | Vérifier et refuser |
| `export.<action>(ctx, args)` | Sur une action nommée, puis `update` s’exécute | Vérifier, refuser et modifier `ctx.root` |

`validate` s’exécute avant les autres hooks sur chaque chemin, donc un seul endroit couvre toutes les portes. Après une action, `update` s’exécute de nouveau contre l’état final, avec `ctx.changed` qui nomme les champs posés par l’action.

Chaque fonction reçoit une table de contexte. Les membres que vous utilisez le plus :

| Membre | Signification |
| --- | --- |
| `ctx.root` | Le contenu du document. Modifiez-le en place. |
| `ctx.patch` | Sur une modification simple : les champs que l’appelant a envoyés. |
| `ctx.changed` | Sur une modification pilotée par une action : les champs posés par l’action. |
| `ctx.action` | Le nom de l’action pendant l’exécution d’une action ; absent sur une modification simple. |
| `ctx.error(msg)` | Recueille un refus. L’écriture échoue alors avec `422`. |
| `ctx.now` | L’heure UTC courante, en texte ISO 8601. |
| `ctx.actor` | L’appelant : `id`, `role_id`, `scope`, `system`. Absent pour les exécutions système ; vérifiez d’abord `ctx.actor == nil`. |

Une règle de forme compte : sur une modification, `ctx.root` est le document **fusionné** — le contenu courant avec le patch déjà appliqué. Un garde-fou qui doit comparer l’ancien et le nouveau lit les champs de l’appelant dans `ctx.patch` (ou `ctx.changed`), pas dans une copie stockée. Le hook update ne peut pas voir l’état d’avant le patch.

## Écrire le garde-fou

Mettez chaque refus dans `validate` — il s’exécute en premier, donc un seul endroit couvre chaque chemin. Une règle qui compare le changement de l’appelant avec l’état stocké vit dans `update`, et lit le changement dans `ctx.patch`. Le script de la réservation Brightwater verrouille les dates d’une réservation confirmée :

```lua
-- rentals.Booking.lua — le garde-fou, complet
function export.update(ctx)
    if ctx.action ~= nil then
        return
    end
    if ctx.patch == nil then
        return
    end
    if ctx.patch.dates ~= nil and ctx.root.status == "confirmed" then
        ctx.error("A confirmed booking's dates are locked. Return the booking first.")
    end
end
```

Les deux premières vérifications comptent. `ctx.action` est défini pendant l’exécution d’une action, et le garde-fou ne doit pas refuser l’action **confirm**, qui pose légitimement un nouvel état. `ctx.patch` est absent quand aucun patch n’a piloté la modification.

## Écrire les hooks et les actions

Modifiez `ctx.root` pour les corrections que votre modèle exige, et refusez avec `ctx.error` quand un état est incorrect. Le même script peut porter des actions — voir [Ajouter des actions à un doctype](/fr/build/model/behaviour/named-actions/). Une recette couvre un cas courant : forcer le responsable à partir du périmètre de permission de l’appelant.

```lua
-- Hook create : force le responsable pour les appelants limités
-- à leurs propres enregistrements.
function export.create(ctx)
  if ctx.actor == nil then return end
  if ctx.actor.scope == "mine" and ctx.actor.system == false then
    ctx.root.owner_id = ctx.actor.id
  end
end
```

## Attacher le script

La définition porte le code source dans son champ `script`. Dans l’éditeur de doctypes, vous modifiez le script directement ; Facet le compile à l’enregistrement et signale les erreurs avec les numéros de ligne. En mode fichiers, le script se trouve à côté du YAML du doctype comme un fichier `.lua` que la définition lit avec `!read_file` :

```yaml
# rentals.Booking.yml
script: !read_file rentals.Booking.lua
```

Une écriture refusée répond `422` et porte votre message. Rien n’est stocké.

## Dépannage

**Chaque écriture répond `422` avec une erreur de script.**

Le script a levé une erreur en dehors de vos appels `ctx.error`. Le message nomme la ligne. Une cause fréquente est un champ nil : vérifiez avant de comparer.

**L’écriture répond avec la limite d’instructions.**

Le script a tourné trop longtemps, le plus souvent dans une boucle sans borne. Facet arrête un script à 1 million d’instructions, 0,5 seconde ou 32 mégaoctets de mémoire, au premier seuil atteint.

**Ma correction ne prend pas effet tout de suite.**

Le cache des définitions se met à jour une à deux secondes après l’enregistrement du doctype. Retestez après un court instant.

**Le script doit modifier un autre document.**

Utilisez les aides `document.*` : `document.create`, `document.get`, `document.update`, `document.delete` et `document.list`. Elles s’exécutent dans les hooks et les actions, et restent dans le même domaine — les écritures ne traversent pas les domaines. Enveloppez un appel dans `pcall` quand un échec est acceptable. Un champ calculé n’a pas le droit d’écrire.

## Voir aussi

- [API Lua](/fr/reference/lua-api/) — toute la surface de script, les aides et les limites.
- [Ajouter des actions à un doctype](/fr/build/model/behaviour/named-actions/) — la moitié action du même script.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — où une écriture refusée ou acceptée est enregistrée.
- [Champs calculés](/fr/build/model/data/computed-fields/) — dériver automatiquement des valeurs de champs.
