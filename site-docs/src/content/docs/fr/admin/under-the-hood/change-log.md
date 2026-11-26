---
title: Le journal des mutations
description: Chaque écriture acceptée ajoute une ligne qui note qui a modifié quoi, comment et pourquoi, et alimente l’audit et le retour arrière.
audience: [evaluator, developer]
features: [AUD-01, AUD-05, AUD-08, DOC-08]
sidebar:
  order: 3
verified_at: 7a6cb462
---

Facet garde l’historique dans une simple table de base de données. Chaque
écriture acceptée ajoute exactement une ligne à `mutations`. La ligne
enregistre le changement, l’acteur et la cause. Les lectures ne passent
jamais par le journal ; elles lisent l’état courant dans les projections.

## Explication

| Groupe | Colonnes | Ce qu’elles enregistrent |
| --- | --- | --- |
| Cible | `domain`, `doc_type`, `doc_id`, `idx` | Quel document a changé, et son ordre dans l’historique de ce document |
| Contenu | `action`, `arguments` | `create`, `update`, `delete` ou `snapshot`, avec contenu ou diff |
| Provenance | `actioner_id`, `channel`, `app`, `api_key`, `acting_role` | Qui a écrit la ligne, et par quelle surface |
| Cause | `cause_kind`, `cause_name`, `cause_event`, `cause_source`, `cause_parent`, `cause_trace` | Ce qui a déclenché l’écriture, un maillon par ligne, et son cluster causal |

Le journal n’accepte que les ajouts. Aucun chemin applicatif ne modifie une
ligne en place. Une écriture que les contrôleurs refusent ne laisse aucune
ligne, car la vérification de permission tourne avant tout changement en
base. Les écritures système portent les mêmes mentions : la colonne du canal
n’est jamais vide, triggers de base de données compris.

Un trigger de base de données applique chaque mutation à `projections`, la
table qui porte l’état courant. Les lectures ne rejouent jamais
l’historique. La projection stocke l’id de sa dernière mutation, et les
lectures renvoient cet id comme ETag, le token de concurrence qu’un client
vérifie avec `If-None-Match`. Les copies de documents suivent le même
chemin : une copie ajoute ses propres lignes `create` par le même client de
mutation, avec la même forme d’audit que n’importe quelle autre écriture.

Deux mécanismes gardent la table bornée :

- **Fusion à l’écriture.** Quand le même acteur écrit par le même canal avec
  les mêmes identifiants dans la fenêtre (trois minutes par défaut), Facet
  fusionne les deux mises à jour en une seule ligne. La ligne fusionnée
  reçoit un nouvel id. L’ancien id cesse de se résoudre pour le reste de la
  fenêtre ; un fetch répond `404`. La projection stocke le nouvel id, donc
  son ETag correspond au contenu servi. Une fenêtre à zéro désactive la
  fusion.
- **Compactage de rétention.** Un job quotidien remplace chaque mutation
  plus vieille que la fenêtre de rétention (180 jours par défaut) par un
  seul instantané synthétique. Le rejeu reste possible à partir de cette
  limite. La profondeur du retour arrière égale la fenêtre : une cible plus
  vieille que la fenêtre répond `404`. Un document supprimé garde son
  delete final et la ligne qui le précède, la restauration reste donc
  accessible dans la fenêtre.

:::caution
Ne traitez pas un id de mutation comme une référence permanente. Une fusion à
 l’écriture fait répondre `404` à l’ancien id dans la fenêtre, et le
compactage retire les lignes au-del à de la fenêtre de rétention. Lisez
l’historique du document quand vous avez besoin des lignes courantes.
:::

### Pourquoi ce n’est pas de l’event sourcing de domaine

Dans cette application, le journal sert deux usages : l’audit et l’état. Le
rejeu existe, mais seulement en interne — le retour arrière et le compactage
rejouent les lignes d’un document pour reconstruire un état. Aucun
consommateur externe ne rejoue le journal. Ce n’est pas le contrat
d’intégration du produit.

**Les réactions voyagent à part.** Les réactions à une écriture passent par
un autre mécanisme. Après le commit en base, le chemin d’écriture publie des
événements sur Redis Streams. Hooks, webhooks, réplication et mises à jour
en direct y consomment. La livraison sur ce bus est au plus une fois, par
conception. PostgreSQL reste le référentiel des données.

**Les compromis sont assumés.** La fusion masque les états intermédiaires :
deux sauvegardes rapides ne laissent qu’une seule ligne. Le compactage borne
la profondeur de l’annuler. En échange, le journal reste borné, et le
stockage reste prévisible.

## Voir aussi

- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — la place du
  journal dans le chemin d’écriture.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) —
  l’état courant que le journal alimente.
- [Événements et livraison](/fr/admin/under-the-hood/events-and-delivery/) — le bus de
  réaction, séparé de ce journal.
- [Glossaire](/fr/reference/glossary/) — le terme mutation, défini en une ligne.
- [Gouverner l’accès](/fr/admin/) — les règles de rétention de l’historique
  que le journal garde.
- Internes sur GitHub : [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md),
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
