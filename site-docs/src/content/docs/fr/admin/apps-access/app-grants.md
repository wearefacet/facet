---
title: Ce que les apps peuvent atteindre
description: Réglez ce qu’une app peut tenter avec des attributions, et voyez comment l’attribution et le rôle bornent chaque requête.
type: how-to
audience: [admin]
features: [RBC-08, FE-12]
verified_at: eee55a2
sidebar:
  order: 0
---

Jo, développeuse indépendante, construit l’app de check-out de Brightwater
pour l’entrepôt. Elle liste les réservations du jour et marque les articles
sortis puis rentrés. Ravi la laisse lire les réservations et modifier les
articles — et rien d’autre, ni noms de clients, ni prix. Deux réglages y
pourvoient : une **attribution** nomme ce que l’app peut tenter, et le rôle
avec lequel elle se connecte borne ce qu’elle peut voir et changer. Les deux
bornes s’appliquent ensemble à chaque requête.

Une app externe obtient l’accès par un document d’enregistrement. Cette page
montre comment vous réglez et changez ces bornes. Le modèle qui les
sous-tend est présenté sur
[Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/).

## Quand l’utiliser

- Vous enregistrez une app et devez garder sa portée étroite.
- Une app a besoin de plus ou moins d’accès qu’elle n’en a.
- Vous devez couper une app rapidement.

## Avant de commencer

- **Le droit.** Il vous faut le droit `update` sur les documents `app.App`.
  Les rôles `admin` et `editor` créés par l’initialisation le portent.
- **Le modèle.** Lisez
  [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/)
  pour le modèle derrière cette page.

## Étapes

### 1. Créer l’app

Ouvrez **Configurer → Applications** et lancez l’assistant. Choisissez un
préréglage : une app web que vous hébergez se connecte par le navigateur ;
une app backend se connecte avec une clé d’API. L’étape de configuration
recueille le nom, les origines de connexion et les adresses de redirection.

<!-- screenshot: configure-apps-wizard-permissions -->

### 2. Régler les attributions

L’étape Autorisations — ou l’onglet Octrois d’une app existante — liste
chaque doctype par domaine. Donnez un niveau d’accès par doctype :

| Niveau | Actions accordées |
| --- | --- |
| Aucun | aucune entrée |
| Lecture | `read` |
| Écriture | `read` + `write` — `write` couvre create et update |
| Complet | `read` + `write` + `delete` |

Les actions nommées que le doctype déclare apparaissent comme interrupteurs
supplémentaires dès que le niveau dépasse Aucun. Un doctype enfant hérite
du niveau de son parent dans l’éditeur ; l’enregistrement écrit une entrée
explicite pour lui.

:::note[Les cibles sont concrètes]
Une attribution nomme un seul doctype, par exemple `crm.Contact`. Les
cibles avec joker sont refusées. Une app qui rend des libellés ou des
définitions a besoin d’une attribution de lecture explicite sur
`core.DocType`, ou elle code les valeurs en dur.
:::

L’app de check-out de Brightwater porte ces attributions :

```json
{
  "grants": [
    {"target": "rentals.Booking", "actions": [{"name": "read", "required": true}]},
    {"target": "rentals.BookingLine", "actions": [{"name": "read", "required": true}]},
    {"target": "equipment.Item", "actions": [{"name": "read", "required": true}, {"name": "write", "required": true}]}
  ]
}
```

L’app lit les réservations du jour et leurs lignes, et lit et écrit les
articles. Elle ne peut atteindre ni sociétés, ni contacts, ni aucun autre
doctype.

### 3. Épingler le rôle de service (apps backend)

Une app backend agit par une identité machine. Choisissez son unique rôle à
l’étape Autorisations. L’éditeur avertit quand le rôle manque d’une action
d’attribution requise, par exemple `missing: update on fin.Invoice`.
L’avertissement ne bloque pas l’enregistrement ; la vraie vérification
tourne à chaque requête. Le rôle doit lister `api` dans ses canaux de
connectivité, sinon l’émission de clé refuse.

### 4. Publier et émettre les identifiants

Publier met le statut de l’app à `active`. Une app web reçoit son client id
et se connecte par l’écran de consentement. Une app backend émet une clé
d’API ; la clé brute s’affiche une seule fois.

### 5. Changer ou révoquer

Modifiez les attributions dans l’onglet Octrois, ou désactivez l’app. Facet
relit le document de l’app à chaque requête, si bien qu’un changement
s’applique à la requête suivante. Rien n’a besoin d’être réémis.

## Explication

### Deux bornes, pas une

L’attribution est le plafond : elle nomme les chemins de doctypes et les
actions que l’app peut tenter. Le rôle décide de ce qui existe à accorder :
Facet ne garde que les actions que le rôle donne aussi. Les périmètres de
lignes du rôle s’appliquent inchangés à l’intérieur des chemins accordés.
Une attribution n’élargit jamais un filtre de lignes.

### La pré-vérification d’attribution

Chaque point d’entrée de lecture, d’écriture et d’action exécute d’abord la
pré-vérification d’attribution. Une combinaison de domaine, de chemin et
d’action qu’aucune attribution ne nomme est refusée. Une app dont
l’ensemble d’attributions est vide est refusée partout — le refus par
défaut.

### La portée effective est recalculée à chaque requête

Le token ne porte jamais l’attribution. Facet recharge le document de l’app
et recalcule l’intersection à chaque requête. Resserrez une attribution, et
la requête suivante tourne sous la borne resserrée.

### Ce que l’app ne peut pas atteindre

La portée effective ne liste que des chemins de doctypes concrets. Une
ligne de rôle avec joker se replie sur chaque doctype accordé. Un doctype
qu’aucune attribution ne nomme répond les mêmes refus qu’un rôle sans
lecture. Par exemple, un token d’app ne peut pas lire `core.DocType` tant
qu’une attribution ne le nomme pas.

### Tokens, clés et consentement

- Un token d’app (`typ: "app"`) emprunte le flux de code d’autorisation
  OAuth avec PKCE et DPoP. L’écran de consentement est toujours affiché, et
  le compte qui autorise élit exactement un rôle pour l’app.
- Une clé d’API possédée par une app (le canal `app_api_key`) authentifie
  le compte de service de l’app. La vérification contrôle aussi l’app : une
  clé pour une app en brouillon ou désactivée répond le `401` uniforme. Le
  droit effectif est attribution ∩ rôle épinglé, calculé à chaque requête.

### L’attribution dans les journaux

Chaque mutation par un canal d’app enregistre l’id de l’app, et la liste
d’audit filtre par lui. Les événements de connexion portent l’id de l’app
pour les sessions d’app. Les refus à la pré-vérification atterrissent dans
le journal des connexions — voir
[Voir qui a fait quoi](/fr/admin/history/audit/).

## Les actions d’attribution

`required: true` signifie que le rôle doit accorder l’action, sinon le rôle
est inutilisable pour l’app. `required: false` signifie que Facet inclut
l’action seulement quand le rôle l’accorde. Son absence ne rejette jamais
le rôle.

## Dépannage

### Chaque route répond `401` avec une clé valable

Le rôle de service ne couvre plus chaque action requise. Le journal du
serveur nomme les actions manquantes, par exemple
`update on fin.Invoice`. Élargissez le rôle ou baissez l’exigence.

### Un appel répond `403` pour un doctype que l’app atteignait avant

L’attribution a été resserrée ou retirée. La requête suivante applique le
changement.

### L’app ne peut pas lire les libellés ou les définitions

Accordez `read` sur `core.DocType`, ou codez les valeurs en dur dans l’app.

### La connexion échoue après une édition de rôle

Une action d’attribution requise manque sur le rôle élu. Vérifiez
l’avertissement dans l’onglet Octrois de l’app.

## Voir aussi

- [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/) —
  le concept.
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) —
  le côté rôle de l’intersection.
- [Clés d’API](/fr/admin/apps-access/api-keys/) — le canal des clés.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — l’attribution des apps
  dans le journal.
- Internes sur GitHub :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
