---
title: Le journal des mutations
description: Chaque écriture acceptée ajoute une ligne qui note qui a modifié quoi, comment et pourquoi, et alimente l’audit et le retour arrière.
type: explanation
audience: [developer, admin]
features: [AUD-01, AUD-05, AUD-08, DOC-08]
verified_at: eee55a2
sidebar:
  order: 1
---

Facet garde l’historique dans une simple table de base de données. Chaque
écriture acceptée ajoute exactement une ligne à `mutations`. La ligne
enregistre le changement, l’acteur et la cause. Les lectures ne lisent
jamais le journal ; elles lisent l’état courant dans les projections. Les
sections suivantes examinent une ligne, les deux mécanismes qui bornent la
table, et la raison pour laquelle Facet ne parle pas d’event sourcing.

*Une écriture, une ligne ; l’état courant est stocké à côté, pas dans la
ligne.*

<!-- d2
direction: down
caller: "Caller writes a document" {class: external}
row: "One row appended to mutations" {class: store}
trigger: "Projection trigger applies the row"
projection: "projections: current state" {class: store}
reader: "Readers and the ETag" {class: external}

caller -> row
row -> trigger
trigger -> projection
projection -> reader
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/78d3a3f0-light.svg" alt="Caller writes a document" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/78d3a3f0-dark.svg" alt="Caller writes a document" loading="lazy" />
</div>

## Les colonnes

| Groupe | Colonnes | Ce qu’elles enregistrent |
| --- | --- | --- |
| Cible | `domain`, `doc_type`, `doc_id`, `idx` | Quel document a changé, et son ordre propre à ce document |
| Contenu | `action`, `arguments` | `create`, `update`, `delete` ou `snapshot`, avec contenu ou diff |
| Provenance | `actioner_id`, `channel`, `app`, `api_key`, `acting_role` | Qui a écrit la ligne, et par quelle surface |
| Cause | `cause_kind`, `cause_name`, `cause_event`, `cause_source`, `cause_parent`, `cause_trace` | Ce qui a déclenché l’écriture, un maillon par ligne, et son cluster causal |

Le journal n’accepte que les ajouts. Aucun chemin applicatif ne modifie
une ligne en place. Une écriture que les contrôleurs refusent ne laisse
aucune ligne, car la vérification de permission tourne avant tout
changement en base. Les écritures système portent les mêmes mentions : la
colonne du canal n’est jamais vide, triggers de base de données compris.

## La projection et l’ETag

Un trigger de base de données applique chaque ligne à `projections`, la
table qui porte l’état courant. Les lectures ne rejouent jamais
l’historique. La projection stocke l’id de sa dernière ligne, et les
lectures renvoient cet id comme ETag. Un client vérifie cet ETag avec
`If-None-Match`. Les copies de documents suivent le même chemin : une
copie ajoute ses propres lignes `create` par le même client de mutation.
La forme d’audit est celle de toute autre écriture.

## Deux mécanismes gardent la table bornée

### La fusion à l’écriture

Quand le même acteur écrit par le même canal avec les mêmes identifiants
dans la fenêtre, Facet fusionne les deux mises à jour en une seule ligne.
La fenêtre est `mutations.coalesce_window_minutes`, trois minutes par
défaut. La ligne fusionnée reçoit un ULID neuf. L’ancien id cesse de se
résoudre pour le reste de la fenêtre ; un fetch répond `404`. La
projection stocke l’id neuf, donc son ETag correspond au contenu servi.
Une fenêtre à zéro désactive la fusion.

Trois règles bornent ce qui peut fusionner :

- Seules les requêtes racines ordinaires fusionnent. Une écriture pilotée
  — la mise à jour propre d’une action, une écriture `document.*`
  imbriquée, un appel d’outil d’assistant, un recalcul de réplication —
  ne fusionne jamais, et ne fusionne jamais dans une autre.
- La fusion compose les deux diffs en un seul, insère la ligne fusionnée,
  puis supprime la ligne précédente. La ligne fusionnée prend le prochain
  `idx` libre, ainsi la position précédente reste vacante — le trou trahit
  les lignes fusionnées.
- Une écriture dont le diff est vide devant le contenu réel n’écrit aucune
  ligne et n’émet aucun événement ; la réponse porte l’ETag courant.

### Le compactage de rétention

Un job quotidien remplace chaque ligne plus vieille que la fenêtre de
rétention (`mutations.retention_days`, 180 jours par défaut) par une
seule ligne `snapshot` synthétique, marquée `cause_kind: compaction`.
L’instantané garde l’horodatage d’origine, ainsi la chronologie d’audit
reste fidèle, et l’ordre des lignes reste contigu. Le rejeu reste possible
à partir de cette limite. La profondeur du retour arrière égale la
fenêtre : une cible plus vieille que la fenêtre répond `404`. Un document
supprimé garde son `delete` final et la ligne qui le précède, ainsi la
restauration reste possible dans la fenêtre.

:::caution
Ne traitez pas un id de mutation comme une référence permanente. Une
fusion à l’écriture fait répondre `404` à l’ancien id dans la fenêtre, et
le compactage retire les lignes au-delà de la fenêtre de rétention. Lisez
l’historique du document quand vous avez besoin des lignes courantes.
:::

## Pourquoi ce n’est pas de l’event sourcing de domaine

Dans cette application, le journal sert deux usages : l’audit et l’état.
Le rejeu existe, mais seulement dans le service — le retour arrière et le
compactage rejouent les lignes d’un document pour reconstruire un état.
Aucun consommateur externe ne rejoue le journal. Ce n’est pas le contrat
d’intégration du produit.

**Les réactions voyagent à part.** Après le commit en base, le chemin
d’écriture publie des événements sur Redis Streams. Hooks, webhooks,
réplication et mises à jour en direct y consomment. La livraison sur ce
bus est au plus une fois, par conception. PostgreSQL reste le référentiel
des données.

**Les compromis sont assumés.** La fusion masque les états intermédiaires :
deux sauvegardes rapides ne laissent qu’une seule ligne. Le compactage
borne la profondeur de l’annulation. En échange, le journal reste borné,
et le stockage reste prévisible.

## Voir aussi

- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — la place du
  journal dans le chemin d’écriture.
- [Documents et projections](/fr/build/deeper/documents-and-projections/) —
  l’état courant que le journal alimente.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) —
  le bus de réaction, séparé de ce journal.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — lire le journal comme
  administrateur.
- [Rétention : ce qui est conservé](/fr/admin/history/retention/) — les
  fenêtres qui bornent la table.
- [Glossaire](/fr/reference/glossary/) — le terme mutation, défini en une
  ligne.
- Internes sur GitHub : [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md),
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
