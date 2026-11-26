---
title: Domaines et isolement
description: "Un domaine regroupe des doctypes et borne leurs données : aucune donnée ne franchit la limite d’un domaine sans consentement explicite."
audience: [evaluator, author]
features: [DOM-01, DOM-14]
sidebar:
  order: 1
verified_at: 7a6cb462
---

Un domaine porte un secteur métier, comme `hr` ou `sales`. Les doctypes,
les hooks et les attributions se trouvent tous à l’intérieur. Rien ne
franchit la limite de son propre chef. Chaque flux inter-domaines exige un
consentement explicite.

## Explication

<!-- d2
domain: Domain {class: external}
boundary: "Read crosses a\ndomain boundary?" {class: decision}
free: No grant needed {class: ok}
grant: "Active domain grant?" {class: decision}
flow: Granted fields flow {class: ok}
refused: Read refused {class: danger}

domain -> boundary
boundary -> free: "no — same domain"
boundary -> grant: "yes — foreign domain"
grant -> flow: "field tags covered"
grant -> refused: "missing or inactive"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/57f6d8f8-light.svg" alt="Read crosses a domain boundary?" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/57f6d8f8-dark.svg" alt="Read crosses a domain boundary?" loading="lazy" />
</div>

**Ce que porte un domaine.** Un domaine est un document `core.Domain`, et
son id est le nom du domaine. Tout id de doctype est donc qualifié, comme
`hr.Employee`. Le domaine doit exister avant l’enregistrement de ses
doctypes ; sinon, l’enregistrement répond `422`.

Le domaine possède ses doctypes et leurs modèles de vue. Il possède aussi
les hooks déclarés sur le document du domaine, et les attributions qu’il
accorde à d’autres domaines. Il possède enfin son état de brouillon : un
domaine de brouillon porte un id qui commence par `_`. Vous publiez un
brouillon dans un nouveau domaine réel. Les attributions ne concernent
jamais des brouillons — les deux côtés doivent être des domaines réels.

**Un domaine se déplace comme un tout.** Le domaine est aussi l’unité de
portabilité. L’export et l’import transportent un domaine avec ses
définitions et ses données.

**L’isolement est la règle par défaut.** Les données ne quittent pas un
domaine de leur propre chef. Une lecture inter-domaines exige l’un de deux
consentements explicites :

- **L’API de documents.** Les lectures suivent les permissions du rôle. Le
  rôle doit porter une ligne de permission qui nomme le doctype étranger.
- **Les surfaces d’automatisation.** Les champs de réplication, les hooks à

  source étrangère et les lectures Lua d’un doctype étranger exigent une
  attribution de domaine active. Sans couverture, la lecture est refusée.

  Les flux au sein d’un même domaine sautent tous ces contrôles. Un domaine
  qui se lit lui-même ne pose pas de décision de partage.

  **Ce que partage une attribution.** Une attribution est un document sous
  le domaine producteur, et une attribution couvre un seul domaine
  consommateur. Elle porte une liste de ressources : une entrée par doctype
  producteur, et chaque entrée nomme des étiquettes de champ. Les
  attributions donnent un accès en lecture seulement — aucun accès en
  écriture n’existe.

  **Un champ est partagé quand ses étiquettes correspondent.** Les champs
  sans étiquette comptent comme `default`, donc une entrée qui nomme
  `default` atteint chaque champ sans étiquette. Le consommateur reçoit
  seulement les champs couverts ; le serveur retire les autres avant la
  livraison.

  **Le producteur décide de l’activation.** L’activation appartient au
  producteur, et elle est tout ou rien par attribution. Une publication qui
  élargit les ressources partagées fait repasser une attribution active en
  inactive. Le producteur doit l’accepter de nouveau.

  **Un seul saut.** La réplication fait un seul saut. Un champ de
  réplication ne peut pas alimenter un autre champ de réplication ; le
  contrôle de création refuse la chaîne avec un `422`.

:::caution
Une attribution agit à la granularité des étiquettes, pas à celle des
rôles. Un domaine consommateur qui détient une attribution sur une
étiquette peut lire ces champs depuis des scripts Lua. L’appelant humain
qui déclenche le script n’a peut-être pas le droit de lire le même champ
par l’API de documents. Accordez une étiquette à un domaine, jamais à un
rôle.
:::

### Le compromis

**Les attributions couplent les domaines.** Le consommateur lit la donnée à

la source, donc il dépend du contrat du producteur. Désactivez
l’attribution : les copies cessent de se mettre à jour. Réduisez les
étiquettes : les valeurs déjà copiées restent en place. Aucun traitement ne
les efface. Réactivez l’attribution : le prochain événement source renvoie
la valeur.

**L’isolement strict coûte de la duplication.** Les deux options sont
pleinement prises en charge. Quand le couplage coûte plus que la copie,
dupliquez le champ et gardez les domaines totalement indépendants.

## Voir aussi

- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — où les
  domaines se situent dans le chemin d’une requête.
- [Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/) —
  créer un domaine et y enregistrer des doctypes.
- [Réplication inter-domaines](/fr/build/deeper/cross-domain-replication/) — le
  mécanisme de copie qu’une attribution contrôle.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) —
  les vérifications de rôle derrière l’API de documents.
- Internes sur GitHub : [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md),
  [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md),
  [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md).
