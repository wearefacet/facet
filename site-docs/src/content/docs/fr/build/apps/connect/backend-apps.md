---
type: how-to
title: Apps backend et comptes de service
description: Donnez un compte de service à une app backend et appelez l’API avec une clé qui lui appartient.
audience: [developer, admin]
features: [APP-07]
sidebar:
  order: 4
verified_at: eee55a2
---

Une app backend a besoin d’une identité de machine. Facet provisionne un
compte de service pour une app `confidential` et lui émet une clé d’API
unique. La clé appelle la même surface REST que tout autre appelant, sous
les mêmes bornes : attribution ∩ rôle épinglé, recalculées à chaque
requête.

> **Pour les agents :** épinglez un rôle de service qui liste le canal de
> connectivité `api`, puis émettez avec `POST /Api/app/{id}/api-key` (une
> clé d’API opérateur dans `Authorization: Bearer`, ou un cookie de session
> plus `X-Requested-With: XMLHttpRequest`). Stockez la valeur brute de
> `key` — elle ne s’affiche qu’une fois. Appelez
> `GET /Api/{domain}/{doctype}` avec `Authorization: Bearer fct_…` ; sans
> en-tête CSRF ni cookie. Pour renouveler, ré-émettez ; révoquez avec
> `DELETE /Api/app/{id}/api-key`. Tout échec de clé répond un simple `401` ;
> le log du serveur nomme les actions d’attribution manquantes.

## Quand l’utiliser

Utilisez un compte de service et sa clé quand :

- une intégration serveur à serveur lit ou écrit des données Facet,
- un job d’intégration continue (CI) ou un job planifié a besoin d’un accès,
- une app `confidential` possède un composant backend qui agit en son
  propre nom.

Préférez la connexion OAuth quand une personne pilote l’app. Utilisez la
clé quand personne n’est au clavier.

## Avant de commencer

- Un enregistrement d’app `confidential` existe — voir
  [Enregistrer une app](/fr/build/apps/connect/register/).
- Vous avez besoin du droit `update` sur `app.App` pour les routes de clé.
- Vous détenez une session navigateur opérateur ; les routes de clé
  refusent un appelant avec clé.
- Le rôle de service liste `api` dans ses canaux de connectivité, et ses
  lignes de permission atteignent les cibles d’attribution de l’app.
  Sinon, l’émission répond `422`.

## Étapes

### 1. Épinglez le rôle de service

Choisissez l’unique rôle à l’étape Autorisations de l’assistant, ou dans
l’onglet Paramètres de l’app. Le rôle décide de ce qui existe à attribuer ;
les attributions de l’app décident de ce qui peut être tenté. À chaque
requête, Facet ne garde que les actions que le rôle accorde aussi. Les
périmètres de lignes du rôle s’appliquent toujours.

Le backend de synchronisation de stock de Brightwater reçoit son propre
rôle aux privilèges minimaux — une ligne de permission concrète, le canal
`api`, rien d’autre. Chaque appel d’API porte son propre identifiant ;
connectez-vous une fois et stockez une clé depuis la CLI :

```sh
pnpx @facetapp/cli connect   # connexion, élection du rôle admin, stockage de la clé
RAVI_KEY=$(pnpx @facetapp/cli apikey)
```

```sh
curl -sk -X POST https://facet.localhost:3443/Api/iam/Roles \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "stock_sync",
    "level": 30,
    "description": "Machine role for the Brightwater stock-sync backend. Reads and writes equipment items over the API.",
    "permissions": [{ "on": "equipment.Item", "action": "*" }],
    "connectivity": ["api"],
    "visible_tags": ["default"]
  }'
```

La création répond `201` ; le rôle réside dans `iam.Roles.stock_sync`.

### 2. Enregistrez l’app comme confidentielle

Une app backend est un enregistrement `confidential` avec le rôle de
service épinglé. Aucune adresse de redirection n’est nécessaire — il n’y a
pas d’aller-retour navigateur :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/app/App \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "brw-stock-sync",
    "name": "Brightwater stock sync",
    "client_type": "confidential",
    "no_launcher": true,
    "service_role_id": "iam.Roles.stock_sync",
    "redirect_uris": [],
    "allowed_origins": [],
    "grants": [
      {
        "target": "equipment.Item",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  }'
```

La création répond `201` avec `client_type: "confidential"`,
`service_role_id: "iam.Roles.stock_sync"` et le `client_id` écrit par le
hook. Activez-la comme toute autre app — `PATCH /Api/app/App/{id}` avec
`{"status": "active"}`.

### 3. Émettez la clé

Appelez la route d’émission avec une clé opérateur. La route provisionne
le compte de service, ré-épingle son rôle et révoque d’abord toute clé
active. Une seule clé active par app existe, donc ré-émettre, c’est faire
une rotation :

```sh
curl -sk -X POST \
  https://facet.localhost:3443/Api/app/06H1G4RS1CQFAC128KPASQFX7H/api-key \
  -H "Authorization: Bearer $RAVI_KEY"
```

La réponse porte la clé brute :

```json
{
  "id": "06H1G4YA6WSM1T1H58V6M3YBQE",
  "key": "fct_9AHD08J0GWCCVWZ064KX2SY7G1",
  "display_prefix": "fct_9AHD08",
  "service_account_id": "06H1G4YA3MM0CESP8SQ6K2GG58",
  "role_id": "iam.Roles.stock_sync"
}
```

Stockez la `key` maintenant. Elle ne s’affiche qu’une seule fois, et
aucune route ne la renvoie ensuite.

Le compte de service apparaît à la première émission. Facet le provisionne
comme un `iam.Account` avec `service_account: true` et l’e-mail
`svc.brw-stock-sync@apps.facet.invalid`. Il porte exactement le rôle
épinglé et ne peut pas se connecter avec un e-mail et un mot de passe.

| Route | Verbe | Comportement |
| --- | --- | --- |
| `/Api/app/:id/api-key` | `POST` | Provisionne le compte de service et émet une clé. Révoque d’abord toute clé active. Renvoie `{id, key, display_prefix, service_account_id, role_id}`. |
| `/Api/app/:id/api-key` | `GET` | Renvoie l’état de la clé — indicateur actif, préfixe d’affichage, rôle, horodatages. Jamais de matière secrète. |
| `/Api/app/:id/api-key` | `DELETE` | Révoque logiquement la clé active. Idempotent. Renvoie `{revoked}`. |

Les trois routes exigent une session opérateur et l’en-tête Cross-Site
Request Forgery (CSRF). Les deux mutations exigent aussi `update` sur
`app.App` ; la route de statut exige `read`. Un appelant avec clé reçoit
`403` : une clé ne peut jamais s’émettre ni se révoquer elle-même.

La route de statut répond :

```json
{
  "active": true,
  "id": "06H1G4YA6WSM1T1H58V6M3YBQE",
  "display_prefix": "fct_9AHD08",
  "role_id": "iam.Roles.stock_sync",
  "created_at": "2026-11-26T13:37:59Z",
  "last_used_at": null
}
```

### 4. Appelez l’API

Envoyez la clé comme token bearer. Aucun en-tête CSRF n’est nécessaire,
car la requête ne porte aucun cookie ambiant :

```sh
curl -sk -H "Authorization: Bearer fct_9AHD08J0GWCCVWZ064KX2SY7G1" \
  "https://facet.localhost:3443/Api/equipment/Item?items=1"
```

```json
{
  "data": [
    {
      "data": {
        "name": "Main tent 10x15",
        "status": "out",
        "category": "equipment.Category.06H1FM176GDKRM4EKNBQAVC94X",
        "serial_number": "TN-10015-A"
      },
      "meta": {
        "id": "EQ-2026-0001",
        "uri": "urn:facet:equipment:Item:EQ-2026-0001",
        "display_name": "Main tent 10x15"
      }
    }
  ],
  "meta": { "count": 40, "more": false }
}
```

La réponse utilise les mêmes formes et les mêmes codes d’erreur que tout
autre appelant. Regardez ce qui manque. `purchase_price` porte
l’étiquette `finance`, et le rôle épinglé ne liste pas cette étiquette —
la clé voit l’article, pas son coût. La permission effective est
attribution ∩ rôle épinglé, et la mutation enregistre l’id de l’app et
l’id de la clé.

La clé peut aussi lire ses propres bornes. Le manifeste sur
`GET /Api/iam/me` montre l’intersection effective, l’identité de la clé et
ses canaux :

```json
{
  "account": {
    "display_name": "Brightwater stock sync",
    "email": "svc.brw-stock-sync@apps.facet.invalid"
  },
  "active_role": "iam.Roles.stock_sync",
  "expires_at": null,
  "connectivity": ["api"],
  "channel": "api",
  "permissions": {
    "equipment.Item": ["read", "create", "update"]
  }
}
```

`expires_at` vaut `null` : une clé n’expire pas d’elle-même. L’attribution
`write` est arrivée sous la forme `create` plus `update`. Voir
[Afficher uniquement ce que l’utilisateur peut faire](/fr/build/apps/connect/permission-manifest/).

### 5. Renouvelez et révoquez

Émettez une nouvelle clé pour renouveler : la route révoque l’ancienne
clé dans la même transaction. Révoquez avec la route delete quand la clé
n’est plus nécessaire :

```sh
curl -sk -X DELETE \
  https://facet.localhost:3443/Api/app/06H1G4RS1CQFAC128KPASQFX7H/api-key \
  -H "Authorization: Bearer $RAVI_KEY"
```

```json
{"revoked": true}
```

## Explication

### Ce que le serveur vérifie à chaque requête

Les vérifications tournent à chaque requête :

- la clé n’est ni révoquée ni expirée,
- le compte de service est vivant et `active`,
- le compte porte toujours le rôle épinglé,
- le rôle liste toujours le canal `api`,
- l’app est vivante et son `status` vaut `active`.

Tout échec répond un simple `401`. Le corps ne nomme rien, donc une clé
divulguée n’apprend rien.

### Une seule clé active par app

La ligne de la clé porte l’id de l’app. Émettre alors qu’une clé active
existe révoque d’abord cette clé, donc le renouvellement est une
ré-émission. La route de statut montre le préfixe d’affichage de la clé
active et sa dernière utilisation, jamais le secret.

:::caution[La clé brute ne s’affiche qu’une fois]
La réponse d’émission est le seul endroit où la clé complète apparaît.
Stockez-la aussitôt dans le magasin de secrets du backend. Une clé perdue
se remplace en émettant une nouvelle clé, ce qui révoque l’ancienne.
:::

## Dépannage

**L’émission répond `422` : « The app's grants do not intersect the service role's permissions ».**

```json
{"error": "The app's grants do not intersect the service role iam.Roles.stock_sync's permissions — the key would be refused at every request. Add a role permission line whose reach covers each grant target (for each grant: {\"on\": \"fin\", \"action\": \"*\"} or {\"on\": \"fin.Invoice\", \"action\": \"*\"}) or widen the role."}
```

Les lignes du rôle épinglé n’atteignent aucune cible d’attribution. Une
ligne à l’échelle d’un domaine — `{"on": "fin", "action": "*"}` — et une
ligne concrète conviennent toutes les deux. Cet échec signifie donc que
les lignes du rôle se trouvent dans d’autres domaines, ou que chaque
ligne qui atteint une cible d’attribution l’exclut avec `except`. Écrivez
la ligne que le message suggère et émettez de nouveau.

**Toutes les routes répondent `401` avec une clé valide.**

Le rôle épinglé ne couvre plus chaque action d’attribution requise. Une
attribution `write` exige des lignes de rôle `create` et `update`. Le
corps reste silencieux par conception ; le log du serveur porte une ligne
WARN qui nomme les actions manquantes, par exemple
`update on fin.Invoice`. Élargissez le rôle ou restreignez les
attributions.

**Les routes de clé répondent `403`.**

Vous les avez appelées avec la clé. Une clé ne peut jamais s’émettre ni se
révoquer elle-même. Utilisez une session opérateur.

**L’émission répond `422` avec « App is not a backend app ».**

Le `client_type` de l’app vaut `public`. Passez-le à `confidential` dans
l’onglet Paramètres de l’app, puis émettez.

**La clé a été émise alors que l’app était encore en `draft`.**

Elle ne s’authentifie qu’une fois l’app passée à `active`. D’ici là,
chaque requête répond `401`, et le log du serveur porte la raison.

## Voir aussi

- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) —
  les bornes derrière la clé.
- [Enregistrer une app](/fr/build/apps/connect/register/) — créer
  l’enregistrement `confidential`.
- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — la surface que la
  clé appelle.
- [Clés d’API](/fr/admin/apps-access/api-keys/) — des clés en libre-service
  pour les personnes.
- [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) —
  le plafond de l’attribution.
- Internes sur GitHub :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
