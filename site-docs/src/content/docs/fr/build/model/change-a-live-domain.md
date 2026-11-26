---
title: Faire évoluer un schéma
description: Modifiez sans risque un doctype publié, avec les incréments de version, les migrations Lua et reproject.
audience: [author]
features: [DOM-17, DOM-18]
sidebar:
  order: 19
verified_at: f1409cdc
---

Chaque document porte la version de schéma avec laquelle il a été écrit. Quand vous modifiez un doctype, les documents plus anciens se mettent à niveau à la lecture : Facet exécute une petite fonction Lua par étape de version et stocke le résultat. Vous écrivez les étapes ; Facet les applique, sans tâche de rattrapage.

## Quand l’utiliser

- Vous ajoutez, renommez ou supprimez un champ sur un doctype publié.
- Vous scindez un champ en deux, ou vous en fusionnez deux en un.
- Des listes ou des libellés affichent des données périmées après un changement de définition.

## Avant de commencer

- **Le droit de mise à jour** sur la définition du doctype.
- **La valeur actuelle de `schema_version`** pour le doctype.
- **Un brouillon fait l’impasse sur tout cela :** modifiez librement, publiez, puis reprenez ici.

## Étapes

### 1. Déterminez le type de changement

À version inchangée, une modification ne peut qu’ajouter des éléments nouveaux : un nouveau champ, une nouvelle clé d’énumération, une nouvelle propriété imbriquée ou une nouvelle entrée enfant. Tout le reste change la forme des données et exige un changement de version accompagné d’une migration :

| Changement | Méthode |
| --- | --- |
| Ajouter un champ | Version inchangée. Les anciennes lignes lisent le champ comme absent. |
| Supprimer un champ ou changer son type | Changement de version avec une migration qui réécrit les lignes. |
| Renommer un champ | Changement de version : ajoutez le nouveau champ, copiez la valeur dans la migration, puis supprimez l’ancien. |
| Resserrer une contrainte ou changer une énumération | Changement de version avec une migration qui répare les valeurs stockées. |

### 2. Incrémentez la version et écrivez la migration

Augmentez `schema_version` d’exactement une unité. Ajoutez une entrée `migrations` dont la clé est la version **de départ**, et écrivez cette fonction dans le script Lua du doctype. La définition porte la correspondance :

```json
{
  "schema_version": 2,
  "migrations": { "1": "migrate_from_1" }
}
```

Le corps de la fonction vit dans le script du doctype ; l’exemple plus bas montre une fonction complète.

:::caution
Une migration réécrit des documents. Une migration qui perd des données n’a pas de retour arrière : `ctx.root.full_name = nil` supprime la valeur. Testez d’abord la fonction sur un brouillon ou sur une copie.
:::

### 3. Laissez les documents se mettre à niveau

Vous ne faites rien. C’est voulu : aucune tâche de rattrapage n’est à lancer. La prochaine lecture ou liste d’un document ancien exécute la chaîne d’étapes dans l’ordre et stocke le résultat. Un document dont l’étape échoue garde son ancien contenu et porte un marqueur d’erreur ; il reste visible.

Un document que personne ne lit garde son ancienne forme ; un corpus se met donc à niveau lentement. Pour porter tous les documents à la version courante d’un coup, ouvrez la page de maintenance du doctype (`/Configure/platform/maintenance`), ou appelez `POST /Api/core/DocType/:id/migrate_ahead`. Les deux sont facultatifs. L’exécution enregistre une mutation `snapshot` (instantané) par document migré — la même trace d’audit que le chemin paresseux laisse document par document, payée ici d’avance.

:::caution
Une migration cassée arrête la mise à niveau, pas le système. Les documents situés avant l’étape cassée gardent leur ancienne forme jusqu’à ce que vous corrigiez la fonction et lanciez `facet doctype:migrate-retry <domain.Doctype>`.
:::

### 4. Reconstruisez les colonnes dérivées avec reproject

Le libellé et le texte de recherche des documents anciens ne suivent pas un changement de modèle. Reconstruisez-les pour tout un doctype :

```sh
facet doctype:reproject crm.Company
```

Options utiles : `--limit 10` pour un essai rapide, `--workers 8` pour accélérer un doctype volumineux. La commande affiche les compteurs `processed`, `superseded`, `skipped` et `failed`.

## Exemple

Le doctype `hr.Employee` passe de la version 2 à la version 3 : `full_name` devient `first_name` et `last_name`. La mise à jour porte l’entrée `"2": "migrate_from_2"`, et le script définit :

```lua
local export = {}

function export.migrate_from_2(ctx)
  local full = ctx.root.full_name
  if full then
    local space = string.find(full, " ")
    if space then
      ctx.root.first_name = string.sub(full, 1, space - 1)
      ctx.root.last_name = string.sub(full, space + 1)
    end
    ctx.root.full_name = nil
  end
end

return export
```

Un document stocké avec `{"full_name": "Ada Lovelace"}` et `meta.schema_version: 2` est lu, migré, puis stocké sous `{"first_name": "Ada", "last_name": "Lovelace"}` avec `meta.schema_version: 3`. L’historique garde l’instantané ; le changement reste auditable.

## Dépannage

**La mise à jour répond : schema_version must be exactly N+1.**

La version a fait un bond. Augmentez d’un cran et publiez chaque étape dans l’ordre.

**La mise à jour répond : Migration from vN to vN+1 is missing.**

La correspondance n’a pas d’entrée pour l’étape que vous quittez. Ajoutez la clé et la fonction, puis enregistrez de nouveau.

**Des documents affichent encore l’ancienne forme.**

Ils ont échoué à leur étape et portent un marqueur d’erreur. Corrigez la fonction et lancez `facet doctype:migrate-retry <domain.Doctype>`.

**Les libellés semblent périmés après un changement de modèle.**

Les colonnes dérivées suivent les écritures, pas les définitions. Lancez `facet doctype:reproject <domain.Doctype>`.

## Voir aussi

- [Référence de l’API Lua](/fr/reference/lua-api/) — la table `ctx` que reçoivent les fonctions de migration.
- [Évolution du schéma](/fr/build/deeper/schema-evolution/) — le modèle de migration paresseuse.
- [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/) — contrôlez d’abord le doctype modifié dans un brouillon.
