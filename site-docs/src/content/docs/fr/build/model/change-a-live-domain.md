---
type: how-to
title: Modifier un domaine réel sans risque
description: Quels changements de doctype sont sûrs sur un domaine réel, lesquels exigent une montée de version, et comment les documents suivent.
audience: [author]
features: [DOM-17, DOM-18]
sidebar:
  order: 5
verified_at: c34885a
---

Chez Brightwater, le doctype `rentals.Booking` est réel : quinze
réservations y sont rangées. Nadia a maintenant besoin d’un champ
`cancellation_reason`, et elle veut le champ libre `notes` en deux
champs structurés. Tout changement d’un doctype réel passe une seule
barrière : le changement modifie-t-il la forme des documents stockés ?
Cette page montre quels changements passent, lesquels exigent une
montée de version avec une migration, et comment les documents stockés
suivent.

## Quand l’utiliser

- Vous ajoutez, renommez ou supprimez un champ sur un doctype réel.
- Vous scindez un champ en deux, ou vous fusionnez deux champs en un.
- Des listes ou des libellés semblent périmés après un changement de
  définition.

## Avant de commencer

- **Des droits de mise à jour** sur la définition du doctype.
- **Le `schema_version` actuel** du doctype.
- **[Les domaines brouillon](/fr/build/model/in-app/how-drafts-work/)
  sautent tout ceci :** modifiez librement, publiez, puis commencez ici.

## Étapes

### 1. Décider du type de changement

Une modification à version égale ne peut qu’ajouter de la surface
nommée. Tout le reste change la forme des données et exige une montée
de version avec une migration :

| Sûr à version égale | Exige une montée de version + une migration |
| --- | --- |
| Ajouter un champ | Supprimer un champ |
| Ajouter une clé d’énumération | Supprimer ou réordonner des clés d’énumération |
| Ajouter une propriété imbriquée | Changer le type d’un champ |
| Ajouter une entrée `children` | Resserrer une contrainte |
| Changer le libellé, la recherche ou les modèles de vue | Changer la surface de référence, ou les liens `children` / `member_of` |
| Changer les icônes, les couleurs, les valeurs par défaut, les étiquettes, les drapeaux lecture/écriture | Inverser une collection, ou éditer un sous-schéma imbriqué |

La règle derrière le tableau : une modification additive ne peut pas
casser un document stocké, parce que la validation ne s’applique qu’aux
nouvelles écritures. Un changement de forme le peut, donc il doit dire
comment chaque document stocké se met à niveau.

### 2. Monter la version et écrire la migration

Montez `schema_version` d’exactement un. Ajoutez une entrée
`migrations` dont la clé est la version **de départ**, et écrivez cette
fonction dans le script Lua du doctype :

```json
{
  "schema_version": 2,
  "migrations": { "1": "migrate_from_1" }
}
```

Le corps de la fonction vit dans le script du doctype ; l’Exemple
ci-dessous en montre une complète. Deux contrôles s’exécutent à
l’enregistrement : chaque écart de version exige son entrée de
migration, et chaque fonction nommée doit exister dans le script.

:::caution
Une migration réécrit des documents. Aucun retour arrière n’existe pour
une migration qui a abandonné des données :
`ctx.root.full_name = nil` supprime la valeur. Testez d’abord la
fonction sur un brouillon ou une copie.
:::

### 3. Laisser les documents se mettre à niveau

Vous ne faites rien. C’est voulu : aucun travail de remplissage n’est à
lancer. La prochaine lecture ou liste d’un document ancien exécute la
chaîne d’étapes dans l’ordre et stocke le résultat. Un document qui
échoue à son étape garde son ancien contenu et porte un marqueur
d’erreur ; il reste visible.

Un document que personne ne lit garde sa vieille forme, donc un corpus
se met à niveau lentement. Pour pousser chaque document vers la version
courante d’un coup, ouvrez la page de maintenance du doctype
(`/Configure/platform/maintenance`), ou appelez
`POST /Api/core/DocType/:id/migrate_ahead`. Les deux sont optionnels.
L’exécution persiste un changement `snapshot` par document migré — la
même empreinte d’audit que le chemin paresseux paie document par
document, payée d’avance.

:::caution
Une migration cassée arrête le rattrapage, pas le système. Les documents
sous l’étape cassée gardent leur vieille forme jusqu’à ce que vous
corrigiez la fonction et lanciez
`facet doctype:migrate-retry <domain.Doctype>`.
:::

### 4. Reconstruire les libellés et la recherche avec reproject

Le texte de libellé et de recherche des documents anciens ne suit pas un
changement de modèle. Reconstruisez-les pour un doctype entier :

```sh
facet doctype:reproject rentals.Booking
```

Options utiles : `--limit 10` pour un test de fumée, `--workers 8` pour
accélérer un grand doctype. La commande rapporte les compteurs traités,
remplacés, ignorés et échoués. Elle reconstruit les trois colonnes
dérivées seulement — libellé, texte de recherche et liens. Elle ne migre
pas les versions.

### 5. Quand la mise à jour est refusée

La barrière répond `422` avec la raison. Les plus courantes :

| Message | Signification | Sortie |
| --- | --- | --- |
| `schema_version must be exactly N+1` | La version a sauté, ou un changement de forme est arrivé sans montée | Montez d’un et enregistrez chaque étape dans l’ordre |
| `Migration from vN to vN+1 is missing` | La table n’a pas d’entrée pour l’étape que vous quittez | Ajoutez la clé et la fonction |
| `same-version edit cannot remove fields` | Un changement de forme à version égale | Montez avec une migration, ou passez `$force: true` |
| `same-version edit must not include migrations` | Un enregistrement à version égale portait une table de migrations | Enregistrez la définition sans la table |
| Valeurs dupliquées nommées | La mise à jour ajoute une contrainte `unique` et des lignes réelles entrent en collision | Corrigez d’abord les données ; le contrôle s’exécute avant toute écriture |

`$force: true` est une échappatoire par enregistrement aux rejets de
forme à version égale. Il n’est jamais stocké : la définition
enregistrée ne le porte pas, et l’enregistrement suivant repart de la
forme stockée. Il ne détend jamais les règles de version. Une
modification forcée peut abandonner la table de migrations stockée —
utilisez-la sur une instance de dev, où la publication suivante
reconstruit tout.

### Publier le brouillon par-dessus le domaine réel

Une publication par écrasement demande une confirmation explicite aux
deux portes. Dans le Builder, Facet refuse la première publication sur
un nom existant (`409`), et la boîte de dialogue propose ensuite
**Publier par-dessus {name}** — confirmez seulement si vous voulez
remplacer la structure réelle. Par l’API, envoyez le drapeau vous-même :

```sh
curl -k -X POST "$(facet-cli host)/Api/core/Domain/<draft-id>/publish" \
  -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"target_name": "rentals", "overwrite": true}'
```

Dans les deux cas, chaque doctype du brouillon dont la structure diffère
du doctype réel doit se trouver exactement un `schema_version` au-dessus
de la version réelle, avec une entrée de migration pour l’étape — la
même barrière que décrit le tableau de l’étape 1.

## Exemple

Le doctype `hr.Employee` passe de la version 2 à la version 3 :
`full_name` devient `first_name` et `last_name`. La mise à jour porte
l’entrée de table `"2": "migrate_from_2"`, et le script définit :

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

Un document stocké avec `{"full_name": "Ada Lovelace"}` et
`meta.schema_version: 2` est lu, migré et stocké comme
`{"first_name": "Ada", "last_name": "Lovelace"}` avec
`meta.schema_version: 3`. L’historique garde l’instantané, donc le
changement est auditable.

Un piège à connaître : une fonction de migration qui ne change rien
marque quand même le document comme migré. Si votre fonction oublie de
toucher `ctx.root`, chaque document saute à la nouvelle version avec son
ancien contenu. La migration ne s’exécute alors plus jamais pour ce
document. Comparez un document avant et après la montée pour la
repérer.

## Dépannage

**La mise à jour répond : schema_version must be exactly N+1.**

La version a sauté. Montez d’un et publiez chaque étape dans l’ordre.

**La mise à jour répond : Migration from vN to vN+1 is missing.**

La table n’a pas d’entrée pour l’étape que vous quittez. Ajoutez la clé
et la fonction, puis enregistrez de nouveau.

**Des documents montrent encore la vieille forme.**

Ils ont échoué à leur étape et portent un marqueur d’erreur. Corrigez la
fonction et lancez `facet doctype:migrate-retry <domain.Doctype>`. La
commande efface le marqueur et relance la migration ; une tentative
échouée n’écrit rien, donc la relance après chaque correction est sûre.
`--limit 10` la plafonne pour un test de fumée.

**Les libellés semblent anciens après un changement de modèle.**

Les colonnes dérivées suivent les écritures, pas les définitions.
Lancez `facet doctype:reproject <domain.Doctype>`.

**La mise à jour abandonne ma table de migrations.**

Un enregistrement avec `$force: true` persiste la définition telle
qu’envoyée, table manquante incluse. Rajoutez les entrées de table à
l’enregistrement suivant. Sur un domaine réel, les enregistrements
normaux portent les entrées stockées en avant même quand le corps les
omet.

## Voir aussi

- [Référence de l’API Lua](/fr/reference/lua-api/) — la table `ctx` que les fonctions de migration reçoivent.
- [Comment les documents anciens suivent un nouveau schéma](/fr/build/deeper/schema-evolution/) — le modèle de migration paresseuse, en détail.
- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) — répétez le changement dans un brouillon d’abord.
- [De la dev à la production](/fr/build/model/dev-to-production/) — ce que la barrière de version de l’import demande à un bundle.
