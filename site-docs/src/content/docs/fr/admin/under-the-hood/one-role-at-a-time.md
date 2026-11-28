---
title: Pourquoi un seul rôle à la fois
description: Chaque requête porte une identité et un seul rôle ; voici comment chaque canal les définit, et pourquoi les rôles ne fusionnent jamais.
type: explanation
audience: [developer, admin]
features: [RBC-10, IAM-14]
verified_at: eee55a2
sidebar:
  order: 2
---

Un onglet de navigateur, une app, un agent et un script en ligne de
commande peuvent appeler la même API. Facet donne à chaque requête la même
forme d’autorisation : une identité et exactement un rôle. Facet appelle
cette paire le **contexte d’authentification**. Voici les moyens de
connexion, et ce que coûte l’unique rôle élu.

*Chaque canal aboutit à une même forme : qui appelle, et sous quel
rôle.*

<!-- d2
direction: down
browser: "Browser session" {class: external}
app: "OAuth app token" {class: external}
mcp: "MCP agent" {class: external}
key: "API key fct_…" {class: external}
context: "One auth context: principal + one elected role" {class: info}
enforcers: "Enforcers check the context"

browser -> context
app -> context
mcp -> context
key -> context
context -> enforcers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e9cff36e-light.svg" alt="Browser session" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e9cff36e-dark.svg" alt="Browser session" loading="lazy" />
</div>

## Les quatre canaux

| Canal | Moyen d’authentification | Ce que contient le contexte |
| --- | --- | --- |
| SPA navigateur (single-page application) | Cookie de session, après connexion | Le compte et le rôle élu |
| App OAuth (un protocole ouvert de délégation) | Token d’app, émis après le consentement de l’utilisateur et l’élection d’un rôle | Le compte, le rôle élu, l’attribution de l’app |
| Agent MCP (Model Context Protocol) | Token bearer ; l’URL épingle le rôle | Le compte et le rôle épinglé |
| Clé d’API | Clé statique (`fct_…`) ; la clé épingle un compte et un rôle | Le compte et le rôle de la clé ; les clés détenues par une app portent aussi l’attribution |

**Un contexte par requête.** Chaque requête aboutit à exactement un
contexte d’authentification. Le contexte porte le principal — qui appelle
— et exactement un rôle élu. Pour un appel d’app, il porte aussi
l’attribution de l’app. Les rôles ne fusionnent jamais : un compte peut
porter trois rôles et n’agir, pour une requête donnée, que sous l’un
d’eux. Une requête s’authentifie par un seul canal, et le contexte
enregistre lequel. Le journal des mutations reporte ce canal dans chaque
ligne d’audit.

**L’attribution est un plafond.** Quand une app appelle, les contrôleurs
vérifient l’attribution avant les permissions propres au rôle. La portée
effective est l’intersection : ce que le rôle permet et ce que
l’attribution nomme. À chaque requête, Facet relit l’attribution depuis le
contenu réel de l’app ; restreindre une attribution prend donc effet à
l’appel suivant, sans nouveau token. Une clé d’API détenue par une app
suit la même règle.

**Le contrôle est identique partout.** Les contrôleurs de lecture et
d’écriture font partie des services de documents, pas de la couche HTTP.
Ils lisent le contexte d’authentification, quel que soit celui qui l’a
construit. Un refus se ressemble sur tous les canaux — navigateur,
application, agent ou clé. Voyez
[Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)
pour les réponses exactes.

## Qui appelle

`GET /Api/iam/me` dit à un appelant qui il est et sous quel rôle il agit.
La réponse porte le compte (id, nom d’affichage, email), le rôle élu
(`active_role`), et les autres rôles du compte (`available_roles`). Elle
porte aussi le manifeste de permissions que le frontend utilise pour
conditionner la navigation et les boutons, ainsi que les `visible_tags`
lisibles par le rôle. Un appelant en session, un token d’app et une clé
d’API reçoivent tous une réponse. Un appelant d’app reçoit un manifeste
restreint à son attribution : du point de vue de l’app, un doctype que
l’attribution ne nomme pas n’existe pas.

:::note
Une requête sans aucun moyen d’authentification tourne sous le rôle
`anonymous` créé par l’initialisation — ses droits de lecture définissent
la surface publique. Un moyen d’authentification présent mais invalide
répond toujours `401`. La requête ne bascule jamais sur `anonymous`.
:::

## Le compromis

Un rôle élu unique interdit l’agrégation de privilèges. Un appelant ne
peut pas porter deux rôles à la fois ; élargir sa portée demande donc un
changement délibéré. Le navigateur propose « Changer de rôle ». Un
consentement OAuth élit un rôle par session. Une URL MCP épingle son rôle
pour toute la session. Chaque chemin est un choix qu’une personne fait, et
le journal d’audit enregistre le rôle qui a agi — c’est là le but.

## Voir aussi

- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) —
  comment les contrôleurs traduisent les permissions en SQL.
- [Attribuer des rôles](/fr/admin/people/assign-roles/) — comment les rôles
  du compte sont attribués et élus.
- [Ce qu’une app peut faire](/fr/build/apps/connect/what-an-app-can-do/) —
  le plafond de l’attribution en détail.
- [Sécurité et gouvernance](/fr/discover/security/) — le modèle de
  permissions résumé pour les auditeurs.
- [Référence](/fr/reference/) — la forme des endpoints, y compris
  l’endpoint d’identité.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md),
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
- [Ne montrer que ce que l’utilisateur peut faire](/fr/build/apps/connect/permission-manifest/)
