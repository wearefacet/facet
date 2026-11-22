---
title: Évolution du schéma
description: Modifiez un doctype sans backfill ; les documents stockés migrent à leur prochaine lecture.
audience: [author, developer]
features: [DOM-17]
sidebar:
  order: 10
verified_at: 7a6cb462
---

Dans Facet, changer un doctype ne réécrit jamais les documents stockés. La
définition passe à une nouvelle version de schéma, et chaque document se met
à jour à la prochaine lecture qui le touche. C’est la migration à la demande :
pas de job de backfill, le travail de migration se fait à la lecture.

## Explication

<!-- d2
direction: right
read: "Read request" {class: external}
fetchDef: "Fetch doctype definition"
fetchDoc: "Fetch document projection"
current: "Stored version is current?" {class: decision}
return: "Return the document" {class: ok}
migrate: "Run the migration functions in order"
snapshot: "Write a snapshot mutation" {class: store}

read -> fetchDef
fetchDef -> fetchDoc
fetchDoc -> current
current -> return: yes
current -> migrate: no
migrate -> snapshot
snapshot -> return
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9bdb23d4-light.svg" alt="Read request" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9bdb23d4-dark.svg" alt="Read request" loading="lazy" />
</div>

Chaque doctype porte un entier `schema_version`, qui démarre à 1. Chaque
document stocke son propre `meta.schema_version` : la version active lors de
sa dernière écriture. Une lecture compare les deux nombres. Quand le nombre
stocké est inférieur, la lecture exécute les fonctions de migration de
chaque écart de version, dans l’ordre. Puis elle enregistre le résultat
comme un instantané et renvoie le document migré. La lecture suivante saute
ce travail, car la version stockée correspond désormais.

**Lectures et listes migrent toutes les deux.** Les lectures individuelles
comme les listes migrent. Une liste migre chaque ligne périmée avant
d’appliquer le masque de lecture. La migration tourne sur une connexion
d’écriture, sous un verrou de ligne. Des lectures concurrentes ne peuvent
donc pas migrer deux fois le même document.

### Le changement de version

Une mise à jour de doctype doit augmenter `schema_version` d’exactement
un — impossible de sauter une version. Chaque écart entre l’ancienne et la
nouvelle version demande une entrée de migration. Chaque fonction nommée
doit exister dans le script Lua du doctype. La map `migrations` de la
définition les nomme :

```json
{
  "schema_version": 3,
  "migrations": {
    "1": "migrate_from_1",
    "2": "migrate_from_2"
  }
}
```

Une fonction de migration est du Lua ordinaire, dans le même script que les
hooks de cycle de vie. Elle modifie le contenu du document en place, et les
hooks de cycle de vie ne se réexécutent pas pendant la migration. Rien
n’est automatique dans un changement de champ — c’est la fonction qui opère
chaque changement :

| Changement | La fonction de migration | Exemple |
| --- | --- | --- |
| Ajouter un champ avec une valeur par défaut | Poser la clé sur l’ancien contenu | `ctx.root.department = "Engineering"` |
| Supprimer un champ | Retirer la clé de l’ancien contenu | `ctx.root.full_name = nil` |
| Changer le type d’un champ | Lire l’ancienne valeur, écrire la nouvelle forme | Scinder `full_name` en `first_name` et `last_name` |

### Quand une migration échoue

Une fonction de migration signale un échec avec `ctx.error`. Facet écrit un
marqueur `migration_error` dans le `meta` du document et renvoie le contenu
périmé. Les lectures et les listes suivantes sautent le document marqué au
lieu d’échouer. Le marqueur indique pourquoi la migration a échoué, vous
pouvez donc lire la cause sans la relancer.

**Réessayer depuis la CLI.** La reprise passe par une commande CLI.
`facet doctype:migrate-retry hr.Employee` efface le marqueur et relance la
migration. Une tentative échouée n’écrit rien, la commande peut donc être
relancée sans risque une fois la définition corrigée.

:::caution
La première lecture après un changement de version paie le coût de la
migration. Le chemin de lecture ouvre une connexion d’écriture et prend un
verrou de ligne sur le document. Un document très consulté, avec un grand
écart de versions, ajoute cette latence à une requête de lecture.
:::

**Le compromis, c’est la coexistence.** Un document jamais lu garde sa forme
ancienne pour toujours. Une fonctionnalité qui a besoin du nouveau champ le
trouve absent sur ces documents. Le coût de la migration retombe sur les
lectures, pas sur le changement de version. En échange, un changement de
schéma se déploie sans backfill de toute la table.

## Voir aussi

- [Faire évoluer un schéma](/fr/build/evolving-schema/) — déclarer les
  champs et la map `migrations` sur un doctype.
- [Brouillon → publication](/fr/concepts/draft-publish/) — répéter d’abord
  un changement de schéma dans un domaine de brouillon.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) —
  où se trouvent le contenu et le meta d’un document.
- Internes sur GitHub : [schema-migration.md](https://github.com/wearefacet/facet/blob/main/doc/backend/schema-migration.md).
