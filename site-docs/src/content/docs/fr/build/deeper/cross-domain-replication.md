---
type: explanation
title: "Réplication entre domaines"
description: "La réplication entre domaines copie des champs choisis du doctype d’un autre domaine : un seul saut, derrière une attribution."
audience: [author, admin]
features: [DOM-25, DOM-14]
sidebar:
  order: 3
verified_at: eee55a2
---

Un doctype consommateur peut copier un champ depuis un doctype source qui
vit dans un autre domaine. La copie est un champ local du document
consommateur, rempli à partir du document source désigné par sa référence.
Facet garde la copie à jour par le bus d’événements. Une attribution de
domaine contrôle ce qui peut franchir la frontière. La version en langage
simple se trouve dans [Les domaines : où vivent vos
données](/fr/discover/how-it-works/domains/).

## Explication

<!-- d2
direction: down
change: "Source document changes"
bus: "Event bus"
handler: "Replication handler"
find: "Find consumer documents through the reference field"
read: "Read the current source value in PostgreSQL"
write: "Write the replica field on each consumer"
reentrant: "Consumer update emits a reentrant event"
skip: "The next handler skips it" {class: ok}

change -> bus
bus -> handler
handler -> find
find -> read
read -> write
write -> reentrant
reentrant -> skip
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/f1eb9af1-light.svg" alt="Source document changes" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/f1eb9af1-dark.svg" alt="Source document changes" loading="lazy" />
</div>

### Fonctionnement de la copie

Le champ réplique du doctype consommateur porte une configuration
`replicate`. Elle nomme un champ référence local (le `via`) et le champ
source à copier. Une connexion de réplication tient donc dans une seule
entrée :

| Partie de l’entrée | Ce qu’elle nomme |
| --- | --- |
| Côté consommateur | Le domaine consommateur, son doctype, le champ référence `via`, le champ réplique |
| Côté source | Le doctype source qualifié, le champ source |
| Politique de suppression | `on_source_delete` — `keep` ou `unset` |

Le moteur construit cette entrée à l’enregistrement de la définition du
doctype, et le registre la garde dans une carte partagée par le processus,
indexée par doctype source. À la création, ou quand le champ référence
change, le chemin d’écriture tire la valeur initiale depuis le document
source. Le tirage s’exécute avant les champs calculés, donc un champ
calculé qui lit la réplique voit la valeur tirée, pas une valeur vide.
Ensuite, chaque changement source se propage par le handler.

Le handler lit toujours la valeur courante de la source dans PostgreSQL —
jamais le payload de l’événement. Il compare cette valeur à la copie de
chaque consommateur et n’écrit que la différence. La mise à jour du
consommateur est une écriture réelle : une ligne de mutation ordinaire,
visible dans le journal d’audit.

**Quel événement source déclenche quoi :**

| Événement source | Ce que fait le handler |
| --- | --- |
| `deleted` | Applique la politique de suppression : `keep` laisse les copies, `unset` vide le champ réplique sur chaque consommateur référençant |
| `created`, `snapshot`, `migrated`, `rolled_back` | Synchronisation complète : retire la valeur pour chaque consommateur référençant |
| `updated`, action | Synchronisation par diff : n’écrit que là où la copie stockée diffère de la source |

**Les champs réplique sont en lecture seule.** Vous ne pouvez pas écrire
vous-même un champ réplique. Le contrôle d’écriture des documents rejette
la clé, et le champ ne peut pas être `required` ni `unique`.

**La copie accuse un retard sur la source.** La livraison passe par le bus
d’événements, donc la copie suit la source avec un décalage : la cohérence
arrive à terme. La livraison est au plus une fois, par conception. Une
mise à jour perdue attend le prochain changement du document source.

**La suppression suit une politique.** Quand un document source est
supprimé, la réplique suit la politique `on_source_delete` du champ.
`keep` (par défaut) laisse la valeur copiée en place. `unset` la vide sur
chaque consommateur référençant. La politique ne touche jamais la
référence `via` elle-même — l’id de la référence reste en place, sans
cible, exactement comme pour tout document supprimé qu’une référence
pointe.

**Les fichiers et textes copiés restent lisibles.** Quand la valeur
répliquée est un champ fichier, le handler ajoute le domaine consommateur
comme propriétaire de l’artefact. Le fichier se lit alors à travers le
document consommateur. Un champ longtext répliqué porte ses liens de
fichiers dans le markdown ; la même règle de propriété s’applique par le
chemin d’écriture normal.

### Un seul saut

Une réplique n’alimente jamais une autre réplique. Le validateur de
doctypes vérifie la définition à l’enregistrement. Il refuse une réplique
utilisée comme source de réplication. Il refuse aussi un champ `via` qui
est lui-même une réplique. À l’exécution, l’écriture qui met à jour une
réplique porte un indicateur réentrant. Un handler qui reçoit un
événement réentrant l’ignore. La chaîne s’arrête à un saut, toujours.

### Ce que le contrôle à l’enregistrement refuse

L’enregistrement de la définition consommatrice répond `422` pour toute
violation bloquante :

- le champ `via` est lui-même une réplique,
- le champ source est une réplique, ou un `secret` — une réplique
  copierait le marqueur d’état du secret dans un contenu public,
- le champ réplique ne porte pas toutes les étiquettes du champ source
  (une étiquette manquante montrerait la valeur copiée à des rôles qui ne
  peuvent pas lire la source),
- la cible de la référence `via` n’est pas un `domain.Doctype` qualifié.

Une source encore introuvable — le doctype ou le champ source n’existe pas
encore — n’est pas un refus bloquant. Un consommateur peut arriver avant
son producteur. Le rapport de vérification nomme ce manque comme
avertissement, et l’exécution laisse la réplique vide jusqu’à ce que la
source existe.

La règle des étiquettes a un ultime garde-fou : une modification côté
producteur qui ajoute une étiquette à un champ source déjà répliqué ne
revalide pas le consommateur. Le rapport de vérification est la surface
qui signale cette dérive.

### Les attributions contrôlent la frontière

Une connexion inter-domaines exige une attribution de domaine active,
stockée sous le domaine producteur. L’attribution nomme le domaine
consommateur et les ressources productrices qu’il peut lire, à la
granularité de l’étiquette. Facet revérifie la couverture à deux moments :

| Vérification | Moment de la vérification | Sans couverture d’attribution |
| --- | --- | --- |
| Construction du registre | au démarrage du serveur, et après tout changement de doctype ou d’attribution | la liaison est abandonnée, donc les mises à jour s’arrêtent |
| Tirage à l’écriture | à la création du consommateur, ou quand le champ référence change | la réplique reste vide |

Les connexions intra-domaine n’ont besoin d’aucune attribution. Un domaine
qui se lit lui-même ne prend aucune décision de partage.

**Révoquer une attribution arrête les mises à jour.** Quand l’attribution
est révoquée, le registre abandonne la liaison à sa prochaine
reconstruction. Les mises à jour s’arrêtent. Les valeurs déjà copiées
restent en place — aucun nettoyage ne les efface. La réactivation ne
rattrape pas le passé. Le prochain changement d’un document source
référencé pousse sa valeur courante dans la copie. Un domaine consommateur
qui gagne sa première liaison tardivement rejoue le flux conservé. Son
groupe de consommateurs démarre à la position `0`, donc l’historique
remplit les répliques — dans la limite de la rétention du flux.

:::caution
Désactiver une attribution ne supprime pas les copies. Les valeurs déjà
répliquées restent dans le domaine consommateur. Traitez les valeurs
copiées comme des données qui survivent au contrat.
:::

**Le registre se reconstruit à la demande.** Un changement de doctype ou
d’attribution ne fait que marquer le registre comme périmé ; la prochaine
lecture le reconstruit. Une rafale de changements — la publication d’un
domaine entier, par exemple — fusionne en une seule reconstruction. La
couverture est revérifiée à chaque reconstruction contre les étiquettes
courantes des champs du producteur : retirer une étiquette coupe des
liaisons, en ajouter une les rétablit.

**Les limites découlent de la conception.** Le saut unique bloque les
chaînes : vous ne pouvez pas router un champ de A vers B puis vers C,
même via un champ calculé. Deux consommateurs de la même source déclarent
chacun leur propre connexion. Et une attribution révoquée laisse la
dernière valeur copiée en place : le consommateur sert des données figées.

## Voir aussi

- [L’isolation entre domaines](/fr/build/deeper/domain-isolation/) — la
  frontière, et ce que partage une attribution.
- [Les domaines : où vivent vos données](/fr/discover/how-it-works/domains/) —
  la même histoire, sans le vocabulaire du moteur.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) —
  le bus qui transporte les mises à jour de réplication.
- [Partager des données entre domaines](/fr/build/model/relations/across-domains/) —
  déclarer la configuration `replicate` sur un champ et attribuer l’accès
  inter-domaines.
- Internes sur GitHub : [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md),
  [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md).
