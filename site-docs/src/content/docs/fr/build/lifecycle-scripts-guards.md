---
title: Scripts de cycle de vie et garde-fous
description: Appliquez vos règles avec des garde-fous et des hooks Lua sur chaque création, modification, suppression et action.
audience: [author]
features: [DOM-08]
sidebar:
  order: 11
verified_at: fd345fe3
---

Un script de cycle de vie s’exécute dans chaque écriture d’un doctype. Il peut
vérifier le document et refuser l’écriture, ou remplir et corriger des champs
avant que Facet ne les stocke. Le script fait partie de la définition du
doctypeà : vos règles voyagent avec le modèle et s’appliquent sur chaque
chemin, l’app, l’API et les agents.

## Quand l’utiliser

Ajoutez un script quand une règle dépasse ce que les contraintes de champ
exprimentà : une date interdite dans le futur, un responsable imposé depuis
l’appelant, un enregistrement fermé aux modifications dans un état donné.
Gardez les règles simples de format dans les contraintes de champ, et les
droits sur les lignes dans les rôles.

## Avant de commencer

- **Lua.** Vous écrivez du Lua. Le script suit un unique motif de moduleà : il
  définit des fonctions et les renvoie dans une table.
- **Un script compilable.** Une erreur de syntaxe bloque l’enregistrement du
  doctypeà : Facet compile le script au moment de l’enregistrement.
- **Pas de valeurs secrètes.** Un script ne voit jamais les valeurs secrètesà ;
  un champ `secret` ne porte ici que son marqueur.

## Étapes

### 1. Connaître les hooks

| Fonction | S’exécute | Peut |
| --- | --- | --- |
| `export.validate(ctx)` | Avant chaque create, update, delete et action | Vérifier et refuser avec `ctx.error` |
| `export.create(ctx)` | Une seule fois, sur create | Vérifier, refuser et modifier `ctx.root` |
| `export.update(ctx)` | À chaque update | Vérifier, refuser et modifier `ctx.root` |
| `export.delete(ctx)` | Sur delete | Vérifier et refuser |
| `export.<action>(ctx, args)` | Sur une action nommée, puis `update` s’exécute | Vérifier, refuser et modifier `ctx.root` |

Chaque fonction reçoit une table de contexte. Les membres que vous utilisez le
plusà :

| Membre | Signification |
| --- | --- |
| `ctx.root` | Le contenu du document. Modifiez-le en place. |
| `ctx.patch` | Sur un update simpleà : les champs envoyés par l’appelant. |
| `ctx.changed` | Sur une action : les champs posés par l’action. |
| `ctx.error(msg)` | Recueille un refus. L’écriture échoue alors avec `422`. |
| `ctx.now` | L’heure UTC courante, en texte ISO 8601. |
| `ctx.actor` | L’appelantà : `id`, `role_id`, `scope`, `system`. Absent pour les exécutions systèmeà ; vérifiez d’abord `ctx.actor == nil`. |

### 2. Écrire le garde-fou

Mettez chaque refus dans `validate`. Il s’exécute avant tous les autres
hooks, donc un seul endroit couvre tous les chemins.

### 3. Écrire les hooks

Modifiez `ctx.root` pour les corrections que votre modèle exige, et refusez
avec `ctx.error` quand un état est incorrect.

### 4. Attacher le script

La définition porte le code source dans son champ `script`. Dans l’éditeur de
doctypes, vous modifiez le script directementà ; Facet le compile à

l’enregistrement et signale les erreurs avec les numéros de ligne.

## Exemple

Le script complet ci-dessous protège un enregistrement d’employéà : pas de
dates d’embauche dans le futur, un responsable imposé depuis le périmètre de
l’appelant, et aucune modification d’un enregistrement clôturé.

```lua
local export = {}

-- Guard: runs before every create, update, delete, and action.
function export.validate(ctx)
  if ctx.root.hire_date and ctx.root.hire_date > ctx.now then
    ctx.error("hire_date cannot be in the future")
  end
end

-- Create hook: force the owner for callers scoped to their own records.
function export.create(ctx)
  if ctx.actor == nil then return end
  if ctx.actor.scope == "mine" and ctx.actor.system == false then
    ctx.root.owner_id = ctx.actor.id
  end
end

-- Update hook: a terminated record is closed for edits. An action that
-- sets a new state runs first, so a valid re-open action still passes.
function export.update(ctx)
  if ctx.root.status == "terminated" then
    ctx.error("A terminated record is closed for edits")
  end
end

return export
```

Une écriture refusée répond `422` et porte votre message. Rien n’est stocké.

## Dépannage

### Chaque écriture répond `422` avec une erreur de script

Le script a levé une erreur en dehors de vos appels `ctx.error`. Le message
nomme la ligne. Une cause fréquente est un champ nilà : vérifiez avant de
comparer, comme le fait l’exemple avec `hire_date`.

### L’écriture répond avec la limite d’instructions

Le script a tourné trop longtemps, le plus souvent dans une boucle sans fin.
Facet arrête un script à 1 million d’instructions, 0,5 seconde ou 32
mégaoctets de mémoire, au premier seuil atteint.

### Ma correction ne prend pas effet immédiatement

Le cache des définitions se met à jour une à deux secondes après
l’enregistrement du doctype. Retestez après un court instant.

### Le script doit modifier un autre document

Utilisez les aides `document.*` : `document.create`, `document.get`,
`document.update`, `document.delete` et `document.list`. Elles tournent dans
les hooks et les actions, et restent dans le même domaine. Enveloppez un
appel dans `pcall` quand un échec est acceptable. Un champ calculé n’a pas le
droit d’écrire.

## Voir aussi

- [API Lua (référence)](/fr/reference/lua-api/) — la surface complète des
  scripts, les aides et les limites.
- [Le journal des mutations](/fr/concepts/mutation-log/) — où une écriture
  refusée ou acceptée est enregistrée.
- [Champs calculés](/fr/build/computed-fields/) — décrire comment dériver
  automatiquement les valeurs de champs.
