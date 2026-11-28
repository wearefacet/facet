---
type: explanation
title: "Évolution du schéma à la demande"
description: "Changez un doctype sans tâche de rattrapage : les documents stockés migrent à leur prochaine lecture."
audience: [author, developer]
features: [DOM-17, DOM-26, DOM-27, DOM-28]
sidebar:
  order: 2
verified_at: eee55a2
---

Dans Facet, un changement de doctype ne réécrit jamais les documents
stockés. La définition passe à une nouvelle version de schéma, et chaque
document se met à niveau à la prochaine lecture qui le touche. C’est la
migration paresseuse : aucune tâche de rattrapage, et le travail de
migration se fait à la lecture. La moitié pratique de ce sujet se trouve
dans [Modifier un domaine réel en toute
sécurité](/fr/build/model/change-a-live-domain/) ; cette page décrit le
mécanisme.

## Le mécanisme

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
document stocke son propre `meta.schema_version` : la version active lors
de sa dernière écriture. Une lecture compare les deux nombres. Quand le
nombre stocké est inférieur, la lecture exécute les fonctions de
migration de chaque écart de version, dans l’ordre. Elle persiste ensuite
le résultat dans une mutation d’instantané et renvoie le document migré.
La lecture suivante saute ce travail, car la version stockée correspond
maintenant.

**Les lectures comme les listes migrent.** Une liste migre chaque ligne
périmée avant d’appliquer le masque de lecture. La migration s’exécute
sur une connexion d’écriture, sous un verrou de ligne. Des lectures
concurrentes ne peuvent donc pas migrer deux fois le même document.

**Une lecture qui doit migrer change de connexion.** Les lectures
s’exécutent normalement sur le pool en lecture seule. Quand un document
est périmé, cette seule requête ouvre un bloc lecture-écriture imbriqué.
Il couvre le verrou de ligne, l’écriture de migration et la relecture de
la ligne migrée. Le reste de la requête reste sur le chemin de lecture.
Une liste change de connexion une fois par requête, pas une fois par
ligne périmée. Un document à jour ne change jamais de connexion ; la
vérification de version est une comparaison en mémoire.

**Chaque migration est auditée.** La mutation d’instantané porte l’acteur
`system:migration`, donc l’historique montre quelles lignes ont bougé et
quand.

### Le saut de version

Une mise à jour de doctype doit augmenter `schema_version` d’exactement
un — impossible de sauter une version. Chaque écart entre l’ancienne et
la nouvelle version exige une entrée de migration. Passer de la version 1
directement à la 3 exige des entrées pour `"1"` et pour `"2"`. Chaque
fonction nommée doit exister dans le script Lua du doctype. La carte
`migrations` de la définition les nomme :

```json
{
  "schema_version": 3,
  "migrations": {
    "1": "migrate_from_1",
    "2": "migrate_from_2"
  }
}
```

Une fonction de migration est du Lua ordinaire, dans le même script que
les hooks de cycle de vie. Elle modifie le contenu du document en place,
et les hooks de cycle de vie ne se réexécutent pas pendant la migration.
Rien d’un changement de champ n’est automatique — la fonction est le lieu
où chaque changement se produit :

| Changement | La fonction de migration | Exemple |
| --- | --- | --- |
| Ajouter un champ avec une valeur par défaut | Poser la clé sur l’ancien contenu | `ctx.root.department = "Engineering"` |
| Retirer un champ | Supprimer la clé de l’ancien contenu | `ctx.root.full_name = nil` |
| Changer le type d’un champ | Lire l’ancienne valeur, écrire la nouvelle forme | Découper `full_name` en `first_name` et `last_name` |

**La carte voyage avec la définition.** Un enregistrement ultérieur qui
omet la carte `migrations` conserve les entrées stockées — le moteur
fusionne la carte stockée sous le corps reçu. Sans ce report, un
enregistrement anodin abandonnerait chaque document encore en dessous de
la version. Un enregistrement avec `$force: true` fait exception : il
persiste le corps tel qu’envoyé, carte incluse ou non.

### Quand une migration échoue

Une fonction de migration signale un échec avec `ctx.error`. Facet écrit
un marqueur `migration_error` dans les meta du document et renvoie le
contenu périmé. Le marqueur indique pourquoi la migration a échoué, donc
vous lisez la cause sans la rejouer. Une erreur d’exécution Lua atterrit
dans le même marqueur, avec le message Lua dedans.

Les lectures et les listes suivantes sautent le document marqué au lieu
d’échouer. Un document cassé ne casse donc jamais une liste paginée — la
ligne reste visible sous son ancienne forme.

**Reprise depuis le CLI.** La reprise passe par une commande CLI.
`facet doctype:migrate-retry hr.Employee` efface le marqueur et rejoue la
migration. Une tentative échouée n’écrit rien, donc la commande peut être
relancée sans risque après correction de la définition. `--limit 10`
limite la course pour un test rapide ; la commande sort avec un code non
nul tant qu’un document échoue encore.

### Une fonction qui ne change rien

Une fonction de migration qui ne touche jamais `ctx.root` est un no-op
silencieux. Le moteur persiste l’instantané avec la nouvelle version,
que le contenu ait changé ou non — il ne compare pas. Le document garde
son ancien contenu, porte le nouveau `schema_version`, et la migration ne
se rejoue plus jamais pour lui. Pour en repérer une, lisez un document
avant et après le saut de version : un contenu inchangé avec une version
augmentée signifie que la fonction a oublié de muter `ctx.root`.

## Pousser tout un corpus en avant

La migration paresseuse laisse un document jamais lu à sa version
d’origine pour toujours. La passe globale pousse chaque document réel à
la version courante en une seule exécution :

- Ouvrez la page de maintenance `/Configure/platform/maintenance`, ou
  postez sur `POST /Api/core/DocType/:id/migrate_ahead`. La route met la
  tâche en file et répond `202` avec une URL de statut.
- L’exécution parcourt les lignes périmées par lots de dix, une
  transaction par ligne. Une ligne déjà migrée par un autre écrivain est
  sautée ; une ligne en échec n’écrit rien.
- Le prix d’audit est le même que celui que le chemin paresseux paie par
  document — une mutation d’instantané par document migré — payé d’avance.
- L’exécution rapporte `Succeeded` même quand des lignes ont échoué ; les
  compteurs font foi. Les lignes qui portent encore un marqueur d’erreur
  restent pour `facet doctype:migrate-retry`.

## Le compromis, c’est la coexistence

Un document jamais lu garde son ancienne forme pour toujours. Une
fonctionnalité qui a besoin du nouveau champ le trouve absent sur ces
documents. Le coût de migration retombe sur les lectures, pas sur le saut
de version. En échange, un changement de schéma part en production sans
parcours de rattrapage sur toute la table.

:::caution
La première lecture après un saut de version paie le coût de migration.
Le chemin de lecture ouvre une connexion d’écriture et prend un verrou de
ligne sur le document. Un document très sollicité, avec un grand écart de
version, ajoute cette latence à une requête de lecture.
:::

## Voir aussi

- [Modifier un domaine réel en toute sécurité](/fr/build/model/change-a-live-domain/) —
  déclarer les champs et la carte `migrations` sur un doctype.
- [Brouillon → publication](/fr/build/model/in-app/how-drafts-work/) —
  répéter un changement de schéma dans un domaine brouillon d’abord.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) —
  où vivent le contenu et les meta d’un document.
- Internes sur GitHub : [schema-migration.md](https://github.com/wearefacet/facet/blob/main/doc/backend/schema-migration.md).
