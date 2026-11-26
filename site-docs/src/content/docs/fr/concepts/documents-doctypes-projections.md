---
title: Documents, doctypes et projections
description: Découvrez comment un doctype forme un document, comment les écritures maintiennent la projection, et ce que signifie l’ETag.
audience: [author, developer]
features: [DOC-01, DOM-03, DOM-23]
sidebar:
  order: 2
verified_at: 7a6cb462
---

Facet découpe un enregistrement en trois parties. Le doctype déclare la
forme. Le document porte les données. La projection garde l’état que les
lectures utilisent. Lisez cette page pour comprendre comment les trois
parties se lient, et ce que coûte cette conception.

## Explication

<!-- d2
definition: "Doctype: the schema"
document: "Document: one JSON instance"
log: "Mutation log: append-only" {class: store}
projection: "Projection: current readable state"
content: "content: the stored JSON"
display: "display_name: label from a template"
search: "search: corpus from a template"
links: "links: reference edges"

definition -> document: shapes
document -> log: write
log -> projection: trigger
projection -> content
projection -> display
projection -> search
projection -> links
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/45bce05b-light.svg" alt="Doctype: the schema" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/45bce05b-dark.svg" alt="Doctype: the schema" loading="lazy" />
</div>

**Le doctype est le schéma.** Un doctype est un type d’enregistrement typé
dans un domaine, comme `hr.Employee`. Sa définition déclare les champs et
leurs types, les actions nommées, les périmètres de lignes et les relations
enfants. La définition est elle-même un document — `core.DocType` — donc
vous l’enregistrez et la versionnez par le même pipeline que n’importe quel
autre enregistrement.

**Le document est la donnée.** Un document est une instance JSON de son
doctype. PostgreSQL le stocke en JSONB. Les routes de documents couvrent le
cycle complet : `POST` crée, `GET` lit, `PATCH` applique un patch par
fusion profonde, `DELETE` passe le document en soft delete, et une route de
restauration ramène un document supprimé. Une mise à jour ne stocke que le
diff calculé, jamais le corps complet.

**La projection est l’état lisible.** Chaque écriture ajoute une ligne au
journal des mutations. Un trigger PostgreSQL applique cette ligne à la
projection dans la même transaction. La projection porte le contenu, le nom
d’affichage, le texte de recherche et les liens entrants. Les lectures
n’analysent jamais le journal. Elles lisent la projection, avec les
périmètres de lignes de l’appelant appliqués en SQL.

**L’id de la dernière mutation est l’ETag.** Chaque ligne de projection
stocke l’id de sa dernière mutation dans sa colonne `state`. Une lecture
d’un seul document renvoie cette valeur dans l’en-tête de réponse `ETag` —
un marqueur de version pour la réponse. Renvoyez-le avec `If-None-Match` :
un document inchangé répond `304 Not Modified`. Un ETag différent à une
lecture ultérieure signifie qu’une autre écriture est passée entre-temps.
Les écritures concurrentes sur un même document sont sérialisées par des
verrous de ligne ; s’il reste une situation de course, elle répond `409`,
et le client rejoue la même requête.

### Colonnes dérivées

Deux colonnes de la projection viennent de modèles Jinja2 définis sur le
doctype. Jinja2 est un langage de modèles venu de l’écosystème Python ;
Facet en fait le rendu en Crystal, au moment de la mutation.

| Colonne | Exemple de modèle | Ce qu’elle porte |
| --- | --- | --- |
| `display_name` | `"{{ first_name }} {{ last_name }}"` | Le libellé du document, tronqué à 255 caractères |
| `search` | `"{{ first_name }} {{ last_name }} {{ email }}"` | Le corpus de recherche, normalisé puis tronqué à 256 caractères |

Dans un modèle `display_name`, un champ référence est remplacé par le
libellé stocké du document cible, et un champ monétaire est rendu sous la
forme `USD 120000`. La troisième colonne dérivée, `links`, n’a pas de
modèle. Le chemin d’écriture parcourt les champs référence et enregistre
les liens ; la page détail les liste comme liens entrants.

**Les modèles sont rendus à chaque écriture.** Un document écrit avant un
changement de modèle garde ses anciennes valeurs jusqu’à la prochaine
écriture sur lui.

:::caution
Changer un modèle `display_name` ou `search` ne reprojette pas les
documents qui existent déjà. Exécutez
`facet doctype:reproject <domain.Doctype>` pour recalculer chaque document
non supprimé du doctype.
:::

**Le compromis.** La projection copie le contenu pour la vitesse de
lecture : un accès à une ligne indexée par document. Chaque écriture en
paie le prix — l’ajout au journal, la mise à jour de la projection et les
colonnes dérivées.

**Deux endroits pour une seule forme.** La logique dérivée se trouve dans
les modèles, à l’écart des définitions de champs : l’auteur d’un doctype
maintient donc deux endroits pour une seule forme.

**Les tombstones gardent leur payload un temps.** Un soft delete garde le
contenu, les liens et le texte de recherche sur la tombstone. La corbeille
peut encore afficher la ligne. Un cron efface ce payload après la fenêtre
de rétention configurée ; seul le libellé survit.

## Voir aussi

- [Concevoir des doctypes](/fr/build/model/data/design-doctypes/) — comment
  déclarer champs, actions et modèles.
- [Construire](/fr/build/) — les pages pratiques pour écrire des domaines.
- [Évolution du schéma](/fr/build/deeper/schema-evolution/) — ce que deviennent
  les documents stockés quand une définition change.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — l’historique en
  ajout seul derrière chaque projection.
- Internes sur GitHub : [document.md](https://github.com/wearefacet/facet/blob/main/doc/backend/document.md),
  [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md),
  [templating.md](https://github.com/wearefacet/facet/blob/main/doc/backend/templating.md).
