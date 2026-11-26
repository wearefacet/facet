---
title: Contextes d’authentification
description: Chaque canal mène à un seul contexte d’authentification, avec un rôle élu, du navigateur à la clé d’API.
audience: [developer, admin]
features: [RBC-10, IAM-14]
sidebar:
  order: 5
verified_at: 7a6cb462
---

Un onglet de navigateur, une application, un agent et un script en ligne de
commande peuvent appeler la même API. Facet donne à chaque requête la même
forme d’autorisation : un contexte d’authentification. Lisez cette page pour
savoir ce que contient ce contexte, et ce que coûte l’unique rôle élu.

## Explication

| Canal | Moyen d’authentification | Ce que contient le contexte |
| --- | --- | --- |
| SPA navigateur (single-page application) | Cookie de session, après connexion | Le compte et le rôle élu |
| Application OAuth (un protocole ouvert de délégation) | Token d’application, émis après le consentement de l’utilisateur et l’élection d’un rôle | Le compte, le rôle élu, l’attribution de l’application |
| Agent MCP (Model Context Protocol) | Token bearer ; l’URL épingle le rôle | Le compte et le rôle épinglé |
| Clé d’API | Clé statique (`fct_…`) ; la clé épingle un compte et un rôle | Le compte et le rôle de la clé ; les clés détenues par une application portent aussi l’attribution |

**Un contexte par requête.** Chaque requête aboutit à exactement un contexte
d’authentification. Le contexte porte l’appelant et exactement un rôle élu.
Pour un appel d’application, il porte aussi l’attribution de l’application.
Les rôles ne fusionnent jamais : un compte peut porter trois rôles et n’agir,
pour une requête donnée, que sous l’un d’eux. Une requête s’authentifie par
un seul canal, et le contexte enregistre lequel. Le journal des mutations
reporte ce canal dans chaque ligne d’audit.

**L’attribution est un plafond.** Quand une application appelle, les
contrôleurs vérifient l’attribution avant les permissions propres au rôle.
La portée effective est l’intersection : ce que le rôle permet et ce que
l’attribution nomme. À chaque requête, Facet relit l’attribution depuis le
contenu réel de l’application ; restreindre une attribution prend donc effet
à l’appel suivant, sans nouveau token. Une clé d’API détenue par une
application suit la même règle.

**Le contrôle est identique partout.** Les contrôleurs de lecture et
d’écriture font partie des services de documents, pas de la couche HTTP. Ils
lisent le contexte d’authentification, quel que soit celui qui l’a construit.
Une lecture refusée répond le même `404` sans divulgation sur tous les
canaux — navigateur, application, agent ou clé.

### Qui appelle

`GET /Api/iam/me` dit à un appelant qui il est et sous quel rôle il agit. La
réponse porte le compte (id, nom d’affichage, email), le rôle élu, et les
autres rôles du compte. Elle porte aussi le manifeste de permissions que le
frontend utilise pour conditionner la navigation et les boutons. Un appelant
en session, un token d’application et une clé d’API reçoivent tous une
réponse. Un appelant d’application reçoit un manifeste restreint à son
attribution : du point de vue de l’application, un doctype que l’attribution
ne nomme pas n’existe pas.

:::note
Une requête sans aucun moyen d’authentification tourne sous le rôle
`anonymous` créé par l’initialisation — ses droits de lecture définissent la
surface publique. Un moyen d’authentification présent mais invalide répond
toujours `401`. La requête ne bascule jamais sur `anonymous`.
:::

**Le compromis.** Un rôle élu unique interdit l’agrégation de privilèges. Un
appelant ne peut pas porter deux rôles à la fois ; élargir sa portée demande
donc un changement délibéré : le navigateur propose « Changer de rôle », un
consentement OAuth élit un rôle par session, et une URL MCP épingle son rôle
pour toute la session.

## Voir aussi

- [Sécurité et gouvernance](/fr/discover/security/) — le modèle de permissions résumé pour les auditeurs.
- [Construire des applications](/fr/build/apps/) — enregistrez une application et faites élire un rôle à ses utilisateurs.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) — comment les contrôleurs traduisent les permissions en SQL.
- [Applications : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/) — le plafond de l’attribution en détail.
- [Référence](/fr/reference/) — la forme des endpoints, y compris l’endpoint d’identité.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
