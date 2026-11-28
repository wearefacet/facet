---
type: explanation
title: "Comment fonctionnent les apps sur Facet"
description: Voyez comment une app Facet s’enregistre, se connecte et appelle l’API sous un plafond d’attributions.
audience: [developer]
features: [APP-01, RBC-08]
sidebar:
  order: 1
verified_at: eee55a2
---

Une app sur Facet est un enregistrement : un document du doctype `app.App`.
Votre code tourne en dehors de Facet et appelle Facet via HTTP. Facet
n’exécute jamais de code d’app et ne donne jamais à une app de connexion à
la base de données. Facet est à la fois la source d’identité et la source
de données. Le document d’enregistrement porte la politique qui encadre
chaque appel que l’app effectue.

> **Pour les agents :** enregistrez l’app avec `POST /Api/app/App` (cookie
> de session plus `X-Requested-With: XMLHttpRequest`) ; le hook de création
> écrit le `client_id` en lecture seule. Une app navigateur se connecte avec
> `GET /OAuth/authorize`, puis `POST /OAuth/token` avec PKCE, et appelle
> `GET /Api/{domain}/{doctype}` avec `Authorization: Bearer` ou
> `Authorization: DPoP` plus une preuve. Une app backend appelle avec
> `Authorization: Bearer fct_…` depuis `POST /Api/app/{id}/api-key`. Chaque
> requête résout attributions ∩ rôle à partir du document d’app courant ;
> une modification d’attribution s’applique donc à la requête suivante.

## Quand l’utiliser

Ouvrez cette page quand :

- Vous construisez un frontend ou une intégration sur Facet.
- Vous devez expliquer pourquoi un appel d’app a été autorisé ou refusé.
- Vous préparez un enregistrement et devez choisir un type de client.

## Avant de commencer

- Lisez [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/) pour
  le modèle d’attributions.
- Enregistrer et modifier des apps exige les droits `update` sur `app.App`. Les
  rôles `admin` et `editor` créés par l’initialisation les portent.

## Explication

### Le document d’enregistrement

Le document d’app porte les champs qui décident de l’identité et de la
portée :

| Champ | À quoi il sert |
| --- | --- |
| `slug` | Nom unique, utilisable dans une URL. Immuable après la création. |
| `client_type` | `public` ou `confidential`. `public` par défaut. |
| `redirect_uris` | Adresses vers lesquelles le flux de connexion peut revenir. |
| `allowed_origins` | Origines navigateur que Facet reflète pour le Cross-Origin Resource Sharing (CORS). |
| `status` | `draft`, `active` ou `disabled`. `draft` par défaut. |
| `grants` | Le plafond de ce que l’app peut tenter. |

`client_id` est un identifiant généré. Le hook de création l’écrit, et
aucun appelant ne peut le changer. Les champs backend comme
`service_role_id` concernent les apps confidentielles — voir
[Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/).
[Enregistrer une app](/fr/build/apps/connect/register/) détaille chaque
champ.

### L’app tourne en dehors de Facet

L’app ne s’exécute jamais dans le processus Facet et ne touche jamais à la
base de données. Chaque lecture et chaque écriture passent par l’API REST.
Comme les attributions font partie du contenu du document, chaque
changement d’attribution passe par l’event sourcing, l’audit et le contrôle
RBAC, comme toute écriture de document.

### Deux types de clients

Une app `public` vit dans le navigateur. Le Proof Key for Code Exchange
(PKCE) protège l’échange de code. Le Demonstrating Proof of Possession
(DPoP) lie le token à une clé. L’écran de consentement s’affiche toujours,
et il n’existe aucun secret.

Une app `confidential` passe par le même écran de consentement et ajoute un
backend. Le backend s’authentifie au nom de l’app avec une clé API propre à
l’app, via un compte de service.

### L’attribution est un plafond

Chaque attribution nomme un chemin de doctype concret, par exemple
`rentals.Booking`. Les cibles génériques sont refusées à l’écriture avec
`422 wildcard_target`. Les actions sont `read`, `write`, `delete`, ou une
action nommée du doctype. `write` se déplie en `create` plus `update` au
moment de la résolution. Une action `required: true` doit aussi figurer sur
le rôle, sinon le rôle est inutilisable pour l’app.

Chez Brightwater, l’app de check-out porte trois attributions : `read` sur
`rentals.Booking` et `rentals.BookingLine` (les deux requises), et `read`
plus `write` sur `equipment.Item` (requise). Cette liste est tout ce que
l’app peut jamais tenter — pour n’importe quel utilisateur.

### Deux limites s’appliquent ensemble

L’attribution pose le plafond. Le rôle décide de ce qui existe à attribuer.
Une app ne peut jamais faire plus que ce que l’app et l’utilisateur ont le
droit de faire : Facet ne garde que les actions présentes dans les deux
ensembles — attributions ∩ rôle. Le rôle vient de l’un de ces deux
endroits :

- **Flux navigateur** — le compte qui se connecte élit un rôle sur l’écran
  de consentement. L’écran s’affiche à chaque connexion.
- **Flux backend** — le rôle de service épinglé sur le document d’app.

Les périmètres de lignes du rôle restent inchangés. Une attribution
n’élargit jamais un filtre de lignes.

Ravi Menon détient le rôle `admin` créé par l’initialisation, dont la
ligne de permission atteint tous les doctypes. Passant par l’app de
check-out, ce même admin n’atteint exactement que les trois doctypes
attribués. La preuve réside dans la vue que le token d’app porte de ses
propres droits, `GET /Api/iam/me` :

```json
"permissions": {
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "equipment.Item": ["read", "create", "update"]
}
```

L’attribution `write` est arrivée comme `create` plus `update` ; rien
d’autre du rôle `admin` n’a transité. Voir
[Afficher uniquement ce que l’utilisateur peut faire](/fr/build/apps/connect/permission-manifest/).

### Recalculé à chaque requête

Le token ne porte jamais l’attribution. Facet recharge le document d’app
courant, résout attributions ∩ rôle, et construit le contexte de la
requête à partir de ce résultat. Une modification d’attribution s’applique
dès la requête suivante ; aucun token n’a besoin d’être réémis.

<!-- d2
direction: down
request: "Request arrives with a token" {class: external}
verify: "AuthHandler verifies the token"
reload: "Reload the live app document"
resolve: "Resolve grant ∩ role"
enforce: "Enforce the grant pre-check, then the role"
run: "Run the operation"
attribute: "Attribute the mutation to the app" {class: store}

request -> verify
verify -> reload
reload -> resolve
resolve -> enforce
enforce -> run
run -> attribute
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9470d917-light.svg" alt="Request arrives with a token" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9470d917-dark.svg" alt="Request arrives with a token" loading="lazy" />
</div>

### Tokens et clés

Un token d’app porte `typ: "app"` et emprunte le flux de connexion OAuth.
Une clé propre à l’app commence par `fct_` et emprunte le canal clé API.
Les deux canaux aboutissent aux mêmes limites : attributions ∩ rôle,
résolues à nouveau à chaque requête.

### Le lanceur du tableau de bord

`GET /Api/iam/apps` liste les apps actives qu’un membre peut ouvrir. Chaque
carte porte un indicateur `usable` : le rôle du membre couvre chaque action
d’attribution requise, sinon la carte s’affiche estompée. `no_launcher:
true` retire un enregistrement headless de la liste.

### Une app ne peut pas élargir son propre plafond

Un appelant sous identité d’app détient `update` sur `app.App` ; le modèle
standard, à lui seul, lui permettrait donc d’élargir son propre plafond.
Le hook de mise à jour refuse tout patch qui porte `grants` ou
`service_role_id` et qui vient d’un appelant sous identité d’app. Une
session opérateur garde tous les droits de modification.

### Imputation

Chaque mutation passée sous identité d’app enregistre l’id de l’app dans
`mutations.app`. La liste d’audit filtre avec `app__eq`. Les événements de
connexion portent l’imputation de l’app : les consentements accordés, les
refresh de token, et les refus à la prévérification des attributions.
Voir [Auditer l’activité](/fr/admin/history/audit/).

## Dépannage

**Un appel répond `403 {"error": "Forbidden"}` sur un doctype que l’app
atteignait avant.**

L’attribution a été réduite ou retirée. La requête suivante tourne déjà
sous la limite resserrée.

**L’app ne peut pas lire les libellés ou les définitions.**

Un token d’app ne peut pas lire `core.DocType` tant qu’aucune attribution
ne le nomme. Accordez `read` sur `core.DocType`, ou codez les valeurs en
dur dans l’app.

**L’app manque au lanceur du tableau de bord.**

`no_launcher: true` la cache, ou `status` vaut `draft` ou `disabled`.

**Un PATCH qui définit `grants` échoue depuis les identifiants de l’app
elle-même.**

Le hook de mise à jour refuse l’auto-élargissement. Modifiez l’app depuis
une session opérateur.

## Voir aussi

- [Enregistrer une app](/fr/build/apps/connect/register/) — créer
  l’enregistrement.
- [Connecter les utilisateurs](/fr/build/apps/connect/user-login/) — la
  connexion navigateur.
- [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/) —
  le canal des clés.
- [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/) — le
  concept derrière les deux limites.
- [Contrôler ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) — la
  vue admin.
- Internes sur GitHub :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
