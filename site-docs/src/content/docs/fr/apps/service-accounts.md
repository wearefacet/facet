---
title: Comptes de service pour les apps backend
description: Donnez une identité de machine à une app backend et appelez l’API avec une clé d’app.
audience: [developer, admin]
features: [APP-07]
sidebar:
  order: 7
verified_at: a77c6171
---

Une app backend a besoin d’une identité de machine. Facet provisionne un
compte de service pour une app `confidential` et lui émet une clé d’API. La
clé appelle la même surface REST que tout autre appelant, sous les mêmes
bornesà : attribution ∩ rôle épinglé, recalculés à chaque requête.

> **Pour les agentsà :** épinglez un rôle de service qui liste le canal de
> connectivité `api`, puis émettez avec `POST /Api/app/{id}/api-key` (cookie
> de session opérateur plus `X-Requested-With: XMLHttpRequest`). Stockez la
> valeur brute de `key` — elle ne s’affiche qu’une fois. Appelez
> `GET /Api/{domain}/{doctype}` avec `Authorization: Bearer fct_…` ; sans
> en-tête CSRF ni cookie. Pour faire tourner, ré-émettezà ; révoquez avec
> `DELETE /Api/app/{id}/api-key`. Chaque échec de clé répond un simple `401` ;
> le log du serveur nomme les actions d’attribution manquantes.

## Quand l’utiliser

Utilisez un compte de service et sa clé quandà :

- une intégration serveur à serveur lit ou écrit des données Facet,
- un job d’intégration continue (CI) ou un job planifié a besoin d’accès,
- une app `confidential` possède un composant backend qui agit en son propre
  nom.

Préférez la connexion OAuth quand une personne pilote l’app. Utilisez la clé
quand personne n’est au clavier.

## Avant de commencer

- Un enregistrement d’app `confidential` existe — voir
  [Enregistrer une app](/fr/apps/registering-app/).
- Vous avez besoin du droit `update` sur `app.App` pour les routes de clé.
- Vous détenez une session navigateur opérateurà ; les routes de clé refusent
  un appelant avec clé.
- Le rôle de service liste `api` dans ses canaux de connectivité. Sinon,
  l’émission répond `422`.

## Étapes

### 1. Épingler le rôle de service

Choisissez l’unique rôle à l’étape Autorisations de l’assistant, ou dans
l’onglet Paramètres de l’app. Le rôle décide de ce qu’il est possible
d’attribuerà ; les attributions de l’app décident de ce qui peut être tenté. À chaque
requête, Facet ne garde que les actions que le rôle accorde aussi. Les
périmètres de lignes du rôle s’appliquent toujours.

### 2. Émettre la clé

Appelez la route d’émission depuis une session opérateur. La route provisionne
le compte de service, ré-épingle son rôle, et révoque d’abord toute clé
active — une seule clé active par app, donc ré-émettre, c’est faire une
rotation :

```sh
curl -s -b cookies.txt -X POST \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
```

La réponse porte la clé bruteà :

```json
{
  "id": "01JHQ8XC4M7T2WY9PB5K3NR6QD",
  "key": "fct_7QW2N8XC4M5T3WY9PB6K1RD4EN",
  "display_prefix": "fct_7QW2N8XC",
  "service_account_id": "iam.Account.01JHQ9D8N2W5XK7PB3T6YR9M4C",
  "role_id": "iam.Roles.integration"
}
```

Stockez la `key` maintenant. Elle ne s’affiche qu’une seule fois, et aucune
route ne la renvoie ensuite.

Le compte de service apparaît à la première émission. Facet le provisionne
comme un `iam.Account` avec `service_account: true` et l’e-mail
`svc.<slug>@apps.facet.invalid`. Il ne porte que le rôle épinglé et ne peut
pas se connecter avec un e-mail et un mot de passe.

| Route | Verbe | Comportement |
| --- | --- | --- |
| `/Api/app/:id/api-key` | `POST` | Provisionne le compte de service et émet une clé. Révoque d’abord toute clé active. Renvoie `{id, key, display_prefix, service_account_id, role_id}`. |
| `/Api/app/:id/api-key` | `GET` | Renvoie l’état de la clé — indicateur actif, préfixe d’affichage, rôle, horodatages. Jamais de matière secrète. |
| `/Api/app/:id/api-key` | `DELETE` | Révoque logiquement la clé active. Idempotent. Renvoie `{revoked}`. |

Les trois routes exigent une session opérateur et l’en-tête Cross-Site Request
Forgery (CSRF). Les deux mutations exigent aussi `update` sur `app.App` ; la
route de statut exige `read`. Un appelant avec clé reçoit `403` : une clé ne
peut jamais s’émettre ni se révoquer elle-même.

### 3. Appeler l’API

Envoyez la clé comme token bearer. Aucun en-tête CSRF n’est nécessaire, car la
requête ne porte aucun cookie ambiantà :

```sh
curl -s -H "Authorization: Bearer fct_7QW2N8XC4M5T3WY9PB6K1RD4EN" \
  "https://facet.company.tld/Api/crm/Company?per_page=5"
```

La réponse utilise les mêmes formes et les mêmes codes d’erreur que tout
autre appelant. La permission effective est attribution ∩ rôle épinglé, et la
mutation enregistre l’id de l’app et l’id de la clé.

### 4. Faire tourner et révoquer

Émettez une nouvelle clé pour faire tournerà : la route révoque l’ancienne clé
dans la même transaction. Révoquez avec la route delete quand la clé n’est
plus nécessaireà :

```sh
curl -s -b cookies.txt -X DELETE \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
```

## Explication

### Ce que le serveur vérifie à chaque requête

Les vérifications tournent à chaque requêteà :

- la clé n’est ni révoquée ni expirée,
- le compte de service est vivant et `active`,
- le compte porte toujours le rôle épinglé,
- le rôle liste toujours le canal `api`,
- l’app est vivante et son `status` vaut `active`.

Tout échec répond un simple `401`. Le corps ne nomme rien : une clé divulguée
n’apprend rien.

### Une seule clé active par app

La ligne de la clé porte l’id de l’app. Émettre alors qu’une clé active existe
révoque d’abord cette clé, donc la rotation est une ré-émission. La route de
statut montre le préfixe d’affichage de la clé active et sa dernière
utilisation, jamais le secret.

:::caution[La clé brute ne s’affiche qu’une fois]
La réponse d’émission est le seul endroit où la clé complète apparaît.
Stockez-la aussitôt dans le magasin de secrets du backend. Une clé perdue se
remplace en émettant une nouvelle clé, ce qui révoque l’ancienne.
:::

## Exemple

Une séquence complète, de la connexion opérateur à la révocation :

```sh
# 1. Connectez-vous comme opérateur et conservez les cookies de session.
curl -s -c cookies.txt -X POST https://facet.company.tld/Api/iam/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "admin@company.tld", "password": "op-secret"}'

# 2. Émettez la clé de l’app et stockez la valeur brute. Elle ne s’affiche qu’une seule fois.
curl -s -b cookies.txt -X POST \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest" \
  | jq -r .key > deal-bot.key
chmod 600 deal-bot.key

# 3. Appelez l’API avec la clé. Sans en-tête CSRF, sans cookie.
curl -s -H "Authorization: Bearer $(cat deal-bot.key)" \
  "https://facet.company.tld/Api/crm/Company?per_page=5"

# 4. Révoquez une fois terminé. Idempotent.
curl -s -b cookies.txt -X DELETE \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
```

## Dépannage

**Toutes les routes répondent `401` avec une clé valide.**

Le rôle épinglé ne couvre plus chaque action d’attribution requise. Une
attribution `write` exige des lignes de rôle `create` et `update`. Le corps
reste silencieux par conceptionà ; le log du serveur porte une ligne WARN qui
nomme les actions manquantes, par exemple `update on fin.Invoice`. Élargissez
le rôle ou restreignez les attributions.

**Les routes de clé répondent `403`.**

Vous les avez appelées avec la clé. Une clé ne peut jamais s’émettre ni se
révoquer elle-même. Utilisez une session opérateur.

**L’émission répond `422` avec « App is not a backend app ».**

Le `client_type` de l’app vaut `public`. Passez-le à `confidential` dans
l’onglet Paramètres de l’app, puis émettez la clé.

**La clé a été émise alors que l’app était encore en `draft`.**

Elle ne s’authentifie qu’une fois l’app passée à `active`. D’ici làà, chaque
requête répond `401`, et le log du serveur porte la raison.

## Voir aussi

- [Le fonctionnement des apps sur Facet](/fr/apps/how-apps-work/) — les bornes
  qui s’appliquent à la clé.
- [Enregistrer une app](/fr/apps/registering-app/) — créez l’enregistrement
  confidentiel.
- [Utiliser l’API REST](/fr/apps/rest-api/) — la surface que la clé appelle.
- [Accès machineà : clés d’API](/fr/govern/api-keys/) — des clés en
  libre-service pour les personnes.
- [La portée des apps (attributions)](/fr/govern/app-grants/) — le plafond de
  l’attribution.
- Internes sur GitHubà :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
