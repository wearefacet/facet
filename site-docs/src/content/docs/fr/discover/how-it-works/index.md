---
title: Architecture en un coup d’œil
description: Suivez une requête à travers Facet, de l’appelant au bus d’événements, en un schéma.
audience: [evaluator, developer, operator]
features: [RBC-10, AUD-01, AUT-01]
sidebar:
  order: 3
verified_at: 7a6cb462
---

Un schéma couvre tout le chemin d’une requête. Chaque saut ci-dessous explique
une case du schéma.

## Le schéma

<!-- d2
direction: down
spa: "Browser SPA" {class: external}
apps: "Apps: OAuth" {class: external}
agents: "Agents: MCP" {class: external}
api: "HTTP API and MCP"
ctx: "Auth context: identity and one elected role"
enforcers: "Enforcers: role, row and field checks"
mutations: "Mutation log: append-only" {class: store}
projections: "Projections: current state" {class: store}
bus: "Event bus: Redis Streams"
consumers: "Hooks, webhooks, replication, live updates"

spa -> api
apps -> api
agents -> api
api -> ctx
ctx -> enforcers
enforcers -> mutations: write
enforcers -> projections: read
mutations -> projections
projections -> bus
bus -> consumers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/871f5719-light.svg" alt="Browser SPA" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/871f5719-dark.svg" alt="Browser SPA" loading="lazy" />
</div>

## Les sauts

### 1. Les appelants

Trois sortes d’appelants partagent la même API :

| Appelant                                       | Comment il se connecte                                                          | Ce qu’il obtient                                          |
| ---------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Le SPA du navigateur (single-page application) | Un cookie de session, après un mot de passe, une MFA ou une connexion SSO       | Toute l’interface de l’espace de travail                   |
| Une application                                | OAuth 2.1 avec PKCE. L’utilisateur consent et élit un rôle                      | Les droits de ce rôle, réduits par l’attribution de l’application |
| Un agent                                       | MCP (Model Context Protocol) sous un rôle épinglé                               | Les outils que ce rôle peut voir                           |

Les clés d’API statiques et les comptes de service backend entrent aussi par
ici. Une requête sans identifiant tourne sous le rôle `anonymous` créé par
l’initialisation — ses droits de lecture couvrent toute la surface publique de
l’API. Un identifiant présenté mais invalide répond toujours `401` ; il ne
redescend jamais vers anonymous.

### 2. L’entrée — HTTP et MCP

Le backend Crystal sert les routes. Les routes de documents ressemblent à

`/Api/{domain}/{doctype}` ; les routes de plateforme commencent par un segment
en majuscule (`/Api`, `/OAuth`, `/Ws`, `/Healthcheck`). La chaîne
d’authentification refuse un identifiant invalide avant tout gestionnaire.

### 3. Le contexte d’authentification

Facet rassemble l’appelant dans un contexte d’authentification : le
principal, l’unique rôle sous lequel il agit et, pour les applications,
l’attribution. Les rôles ne fusionnent jamais. Humains, applications et
agents agissent tous sous ce même modèle, si bien que le contrôle se comporte
pareil sur chaque canal.

### 4. Les contrôleurs

Les contrôleurs de lecture et d’écriture traduisent les permissions du rôle en
vérifications en base de données :

- Une permission nomme une action, un chemin de doctype et un périmètre de
  lignes facultatif.
- Les périmètres de lignes se compilent en prédicats SQL. Une liste ne
  renvoie que les lignes que le rôle peut voir.
- Les étiquettes de champs masquent les champs invisibles en lecture et
  refusent les écritures vers eux.
- Une lecture individuelle refusée répond le même `404` qu’un document
  manquant.

### 5. Le journal des mutations

Une écriture acceptée ajoute une ligne à la table `mutations` : qui a agi, par
quel canal, sur quel document, avec quel changement, et ce qui l’a causé —
une requête, une action, un hook, un retour arrière. La table n’accepte que
les ajouts. Une tâche de rétention remplace l’historique plus vieux que la
fenêtre de rétention par une seule ligne d’instantané.

### 6. Les projections

Un déclencheur PostgreSQL applique chaque mutation à la table `projections`,
qui garde l’état courant : le contenu, le nom d’affichage, le texte de
recherche et les liens entrants. Les lectures ne relisent jamais le journal.
Elles lisent les projections, avec les prédicats de périmètre du rôle
appliqués. Chaque ligne stocke l’id de sa dernière mutation ; cette valeur
sert d’ETag (jeton de concurrence) pour les écritures optimistes.

### 7. Le bus d’événements

Après le commit en base, le chemin d’écriture publie des événements sur Redis
Streams. Les consommateurs réagissent : les hooks de domaine exécutent du
Lua, les webhooks livrent des enveloppes signées, la réplication copie des
champs entre domaines, et le pont WebSocket pousse les mises à jour en direct
aux navigateurs. La livraison est au plus une fois, par conception. Les
données de référence restent dans PostgreSQL.

Les réactions qui écrivent des documents repassent par le saut 2, sous
l’identité de la réaction, et laissent leurs propres lignes d’audit.

## Vérifiez vous-même

Le document OpenAPI servi décrit la surface de l’API v1. Il demande un
appelant connecté, comme toute lecture du plan de contrôle :

```sh
curl -sS -H "Authorization: Bearer $FACET_TOKEN" \
  https://your-facet-host/Api/openapi.json
```

:::tip
Donnez cette page plus le document OpenAPI à un agent. Le schéma nomme les
sauts ; le contexte d’authentification et le journal des mutations expliquent
pourquoi un agent ne peut ni contourner les droits ni perdre sa piste d’audit.
:::

## Voir aussi

- [Sécurité et gouvernance](/fr/discover/security/) — les règles de contrôle en détail.
- [Qu’est-ce que Facet](/fr/discover/why-facet/) — l’histoire du produit derrière ce schéma.
- [Glossaire](/fr/reference/glossary/) — les termes employés ci-dessus.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
