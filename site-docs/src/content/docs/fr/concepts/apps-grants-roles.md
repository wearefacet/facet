---
title: "Apps : attributions ∩ rôles"
description: Comment une app agit avec l’intersection de son attribution et du rôle élu de l’utilisateur.
audience: [developer, admin]
features: [RBC-08]
sidebar:
  order: 8
verified_at: 7a6cb462
---

Une app qui connecte un utilisateur n’agit jamais avec tous les droits de cet
utilisateur. Elle agit avec l’intersection de l’attribution et du rôle élu.
Lisez cette page pour voir ce que chaque côté apporte.

## Explication

<!-- d2
signin: "User signs in to the app" {class: external}
consent: "Consent screen is always shown"
role: "User elects one role"
grant: "App grant stored on the app document" {class: store}
scope: "Intersection of grant and elected role"
enforcers: "Enforcers apply the effective scope"

signin -> consent
consent -> role
role -> scope
grant -> scope
scope -> enforcers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/31157b28-light.svg" alt="User signs in to the app" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/31157b28-dark.svg" alt="User signs in to the app" loading="lazy" />
</div>

Une app est un document du doctype `app.App`. Son enregistrement porte une
attribution. L’attribution fixe le maximum de ce que l’app pourra jamais
faire, pour chaque utilisateur.

| Élément d’une entrée d’attribution | Contenu |
| --- | --- |
| `target` | un chemin de doctype concret, comme `crm.Contact` ; les cibles joker sont refusées |
| action `name` | `read`, `write`, `delete`, ou une action nommée ; `write` se décompose en `create` et `update` |
| action `required` | à `true`, un rôle qui n’a pas l’action ne peut pas utiliser l’app |

À la connexion, l’utilisateur élit un rôle sur l’écran de consentement. Cet
écran s’affiche toujours, même si l’utilisateur s’est déjà connecté. Facet
calcule ensuite le périmètre effectif. L’app ne peut tenter que ce qui se
trouve dans les deux ensembles.

**L’attribution plafonne même les utilisateurs puissants.** Un rôle admin
atteint tous les doctypes. Par l’app, ce même admin n’atteint que ce que
l’attribution nomme. L’attribution est un plafond ; elle n’élargit jamais un
rôle.

**Un changement d’attribution s’applique à l’appel suivant.** Facet relit
l’attribution à chaque requête, depuis le document d’app réel. Un changement
s’applique donc à la requête suivante, sans nouveau token. Aucun token ne met
l’attribution en cache.

**Les périmètres de lignes se transmettent.** Si le rôle élu limite les
lectures à `$mine`, l’app garde cette limite. L’attribution restreint les
doctypes et les actions qu’une requête peut tenter. Elle n’assouplit jamais un
filtre de lignes.

**Apps backend.** Une app backend n’a pas de connexion utilisateur. Elle
détient une clé d’API (interface de programmation) et un compte de service
avec un seul rôle épinglé. Sa portée est la même intersection : l’attribution
et le rôle épinglé.

**Une app ne peut pas élargir sa propre attribution.** Le hook de mise à jour
sur `app.App` refuse un patch venant d’un appelant limité à l’app. Le patch ne
peut pas changer `grants`, le rôle de service ni le compte de service. Les
opérateurs gardent tous les droits d’édition.

:::tip
Quand toutes les routes répondent `401` avec une clé valide, lisez le journal
du serveur. Une ligne d’avertissement nomme le rôle, l’app, la clé et les
actions manquantes. Élargissez ensuite le rôle, ou resserrez l’attribution.
:::

**Le compromis découle de la conception.** La même app peut marcher pour un
utilisateur et échouer pour un autre. L’attribution est statique, tandis que
le rôle élu varie selon l’utilisateur. Quand l’app échoue, vérifiez les deux
côtés : l’attribution sur le document d’app, et les lignes de permission du
rôle élu.

## Voir aussi

- [Apps](/fr/apps/) — enregistrer une app, modifier son attribution, émettre
  et faire tourner les clés.
- [Contextes d’authentification](/fr/concepts/auth-contexts/) — comment le
  rôle élu et l’attribution accompagnent chaque requête.
- [Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/) —
  le modèle de rôles d’où vient le rôle élu.
- [Gouverner l’accès](/fr/govern/) — modifier les rôles qu’une app peut élire.
- Internes sur GitHub : [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
