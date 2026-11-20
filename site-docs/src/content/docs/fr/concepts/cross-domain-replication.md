---
title: Réplication entre domaines
description: Un domaine consommateur peut copier des champs choisis du doctype d’un autre domaine, en un seul saut, sous le contrôle d’une attribution.
audience: [author, admin]
features: [DOM-25, DOM-14]
sidebar:
  order: 11
verified_at: 7a6cb462
---

Un doctype consommateur peut copier un champ depuis un doctype source qui vit
dans un autre domaine. La copie est un champ local du document consommateur,
rempli depuis le document source vers lequel il pointe. Facet garde la copie à

jour par le bus d’événements. Une attribution de domaine contrôle ce qui peut
franchir la limite.

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

### Comment la copie fonctionne

Le champ répliqué du doctype consommateur porte une configuration `replicate`.
Elle nomme un champ référence local (le `via`) et le champ source à copier. À
la création, ou quand le champ référence change, Facet tire la valeur initiale
du document source. Ensuite, chaque changement de la source se propage. Le
handler lit la valeur courante de la source dans PostgreSQL. Il compare cette
valeur à la copie de chaque consommateur et n’écrit que la différence.

**Les champs répliqués sont en lecture seule.** Vous ne pouvez pas écrire
vous-même un champ répliqué. Le garde-fou d’écriture des documents refuse la
clé, et le champ ne peut pas être `required` ni `unique`.

**La copie prend du retard sur la source.** La livraison passe par le bus
d’événements, donc la copie prend du retard sur la sourceà : la cohérence est
 à terme. La livraison est au plus une fois, par conception. Une mise à jour
perdue attend le prochain changement du document source.

**La suppression suit une politique.** Quand un document source est supprimé,
la réplique suit la politique `on_source_delete` du champ. `keep` (par défaut)
laisse la valeur copiée en place. `unset` la vide sur chaque consommateur qui
référence la source.

### Un seul saut

Une réplique n’alimente jamais une autre réplique. Le validateur de doctypes
vérifie la définition quand vous l’enregistrez. Il refuse une réplique
utilisée comme source de réplication. Il refuse aussi un champ `via` qui est
lui-même une réplique. À l’exécution, l’écriture qui met à jour une réplique
porte un drapeau réentrant. Un handler qui reçoit un événement réentrant le
saute. La chaîne s’arrête toujours à un saut.

### Les attributions contrôlent la limite

Une arête entre domaines a besoin d’une attribution de domaine active, stockée
sous le domaine producteur. L’attribution nomme le domaine consommateur et les
ressources du producteur qu’il peut lire, à la granularité des étiquettes.
Facet revérifie la couverture à deux momentsà :

| Contrôle | Quand il s’exécute | Sans couverture d’attribution |
| --- | --- | --- |
| Construction du registre | au démarrage du serveur, et après tout changement de doctype ou d’attribution | la liaison est abandonnée, et les mises à jour s’arrêtent |
| Tirage à l’écriture | à la création du consommateur, ou quand le champ référence change | la réplique reste nulle |

Les arêtes dans un même domaine n’ont pas besoin d’attribution. Un domaine qui
se lit lui-même ne prend pas une décision de partage.

**Révoquer une attribution arrête les mises à jour.** Quand l’attribution est
révoquée, le registre abandonne la liaison à sa prochaine reconstruction. Les
mises à jour s’arrêtent. Les valeurs déj à copiées restent en place — aucun
balayage ne les supprime. La réactivation ne rattrape pas les changements
manqués. Le prochain changement d’un document source référencé pousse sa
valeur courante dans la copie. Un domaine consommateur qui reçoit sa première
liaison tardivement rejoue le flux conservé. L’historique remplit alors les
répliques dans la limite de la rétention du flux.

:::caution
Désactiver une attribution ne supprime pas les copies. Les valeurs déjà
répliquées restent dans le domaine consommateur. Traitez les valeurs copiées
comme des données qui survivent au contrat.
:::

**Les limites découlent de la conception.** Un seul saut arrête les chaînesà :
vous ne pouvez pas acheminer un champ de A vers B puis vers C, même via un
champ calculé. Deux consommateurs de la même source déclarent chacun leur
propre arête. Et une attribution révoquée laisse la dernière valeur copiée en
place, si bien que le consommateur sert des données figées.

## Voir aussi

- [Domaines et isolement](/fr/concepts/domains-and-isolation/) — pourquoi les
  domaines restent séparés, et ce qui passe.
- [Événements et garanties de livraison](/fr/concepts/events-delivery/) — le
  bus qui transporte les mises à jour de réplication.
- [Partager des données entre domaines](/fr/build/sharing-across-domains/) —
  déclarer la configuration `replicate` sur un champ et accorder l’accès entre
  domaines.
- Internes sur GitHubà : [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md),
  [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md).
