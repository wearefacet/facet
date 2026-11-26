---
title: Sessions, tokens et verrouillages
description: "Voyez où vivent les sessions, comment les tokens tournent, et comment fonctionnent limitation et verrouillages."
audience: [admin]
features: [IAM-01, IAM-02, IAM-10, IAM-11]
sidebar:
  order: 8
verified_at: f1409cdc
---

Facet scinde chaque connexion en deux identifiants. Le token d’accès est un
token signé à courte durée de vie. Le refresh token est un token opaque de
longue durée qui représente une session côté serveur dans Redis. Cette page
explique les deux, la règle de rotation, et le comportement des
verrouillages.

## Quand l’utiliser

- Vous devez expliquer combien de temps fonctionne un token volé.
- Vous devez libérer un compte verrouillé.
- Vous révisez le comportement de session du déploiement.

## Explication

### Où vivent les sessions

Une session est un hash dans Redis sous `session:{id}`. Elle porte les
ids de refresh courant et précédent, l’id du compte, le rôle élu, les
horodatages, le User-Agent, l’adresse du client, et le mode de livraison du
token. Les sessions s’inscrivent aussi dans un ensemble par compte et un
ensemble par app. Une perte complète de Redis ne force qu’une reconnexion ;
rien de durable n’en dépend.

### Le token d’accès

Le token d’accès est un JSON Web Token (JWT) signé avec l’algorithme ES256.
L’algorithme de signature est épinglé ; l’en-tête du token ne le choisit
jamais, ce qui ferme les attaques connues de confusion d’algorithme. La
durée de vie par défaut est de 900 secondes, fixée par
`iam.jwt.access_token_ttl`.

Les claims sur chaque token :

| Claim | Contenu                                              |
| ----- | ----------------------------------------------------- |
| `sub` | L’id du compte.                                       |
| `sid` | L’id de la session.                                   |
| `role`| L’id du rôle élu.                                     |
| `jti` | Un id de token unique.                                |
| `typ` | Le genre de token, `access` pour les sessions navigateur. |

La clé de signature vient de la variable d’environnement `JWT_SIGNING_KEY`,
une clé privée P-256 au format PEM. Quand la variable est absente, chaque
processus génère une clé temporaire et journalise un avertissement une fois.

:::caution
Positionnez `JWT_SIGNING_KEY` en production et sur chaque déploiement
multi-instances. Un redémarrage avec une clé générée invalide chaque token
d’accès en circulation, et des instances séparées ne peuvent pas vérifier
les tokens des autres. Générez une clé avec
`openssl ecparam -name prime256v1 -genkey -noout`.
:::

### Le refresh token et la rotation

Le refresh token est une paire opaque `session_id.refresh_id`. Chaque usage
le fait tourner :

1. L’id de refresh présenté passe en `previous`.
2. Un nouvel id de refresh le remplace.
3. Pendant une fenêtre de grâce de 10 secondes
   (`iam.jwt.refresh_grace_window`), les deux ids sont acceptés, si bien que
   deux requêtes parallèles ne tuent pas la session.

  Un id présenté qui ne correspond à aucun des deux est une réutilisation de
  token. Facet supprime la session aussitôt et écrit un événement
  `refresh_reuse` dans le journal des connexions. Le token d’accès déjà émis
  reste valable jusqu’à son TTL, la même règle qu’une révocation explicite.

  La durée de vie de la session est de 14 jours, fixée par
  `iam.jwt.refresh_token_ttl`. Chaque refresh réussi relance le compte à

  rebours.

### Les modes de livraison

La connexion livre les tokens en cookies HttpOnly ou dans le corps JSON. La
session retient le mode. Un refresh avec l’autre mode répond `422` avant
tout changement d’état : rien ne tourne, la session reste.

### La gestion des sessions

| Route                                  | Ce qu’elle fait                                                                                          |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GET /Api/iam/sessions`                 | Liste les sessions de l’appelant avec ids et métadonnées.                                                   |
| `DELETE /Api/iam/sessions/:session_id`  | Révoque une de ses sessions. Idempotent : un id inconnu répond `200` avec `revoked: false`.                  |
| `DELETE /Api/iam/sessions`              | Révoque chaque session de l’appelant sauf la courante.                                                      |
| `DELETE /Api/iam/apps/:app_id/sessions` | Révoque chaque session que l’appelant détient pour une app.                                                 |

Après une révocation, le token d’accès vivant fonctionne jusqu’à
l’expiration de son TTL ; le refresh suivant échoue parce que la ligne de
session a disparu. Les titulaires de comptes gèrent leurs propres sessions
dans l’espace de travail — voir
[Vos paramètres, sessions et clés d’API](/fr/use/account/).

### La limitation des connexions

La limitation garde son état dans Redis. Cinq compteurs et un indicateur
s’appliquent. Les compteurs et l’indicateur de verrouillage sont des clés
séparées ; un compteur peut expirer pendant que le verrouillage tient
toujours.

| Compteur                                 | Déclencheur                                | Effet                                                                      |
| ----------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------- |
| Tentatives de mot de passe par compte     | 10 mots de passe faux                       | La prochaine tentative pose l’indicateur de verrouillage ; la connexion répond `429`. |
| Tentatives de mot de passe par adresse client | 20 mots de passe faux depuis une adresse | La connexion répond `429` tant que le compteur est à sa limite. Pas d’indicateur de verrouillage. |
| Réponses au défi MFA                      | 5 réponses fausses                          | Le défi est supprimé et l’indicateur de verrouillage est posé.              |
| Vérification MFA à l’enrôlement           | 5 codes faux                                | Le point d’entrée répond `429`. Pas d’indicateur de verrouillage.           |
| Vérification MFA après connexion          | 5 codes faux                                | Le point d’entrée répond `429` tant que le compteur est à sa limite. Pas d’indicateur de verrouillage. |

Chaque compteur expire 300 secondes après son premier incrément, et un
incrément ultérieur ne le prolonge pas. Un succès remet à zéro les compteurs
de mot de passe et le compteur MFA d’après-connexion.

L’indicateur de verrouillage a sa propre clé, `login_lockout:<account_id>`,
avec son propre compte à rebours de 300 secondes. Il démarre quand
l’indicateur est posé, pas quand le compteur qui l’a déclenché a démarré.
L’indicateur est posé par la limite de mot de passe du compte et par le
verrouillage du défi MFA. Tant que l’indicateur est présent, chaque
connexion répond `429` avant toute vérification de mot de passe, même après
l’expiration du compteur qui l’a causé.

La trace d’audit est délibérée : seul le verrouillage écrit une ligne dans
le journal des connexions. Chaque tentative échouée va plutôt dans le
journal du backend, sous `facet.iam.login` au niveau warn, avec l’id du
compte, l’adresse du client, et les tentatives restantes. Voir
[Auditer l’activité](/fr/admin/history/audit/) pour le journal
d’événements.

## Étapes

### Lever un verrouillage

Chaque clé expire d’elle-même 300 secondes après son démarrage. Pour
libérer un compte aussitôt, supprimez les clés Redis sur l’hôte du serveur.

Un nettoyage complet supprime quatre familles de clés :

```sh
redis-cli DEL login_lockout:<account_id> \
  pwd_attempts:<account_id> \
  pwd_attempts:ip:<address> \
  mfa_verify_attempts:<account_id>
```

Remplacez `<account_id>` par l’id du compte et `<address>` par l’adresse du
client. Pour nettoyer chaque compteur par adresse, scannez-les :

```sh
redis-cli --scan --pattern 'pwd_attempts:ip:*' | xargs redis-cli DEL
```

Un nettoyage limité au mot de passe garde le limiteur MFA intact et
supprime trois familles :

```sh
redis-cli DEL login_lockout:<account_id> pwd_attempts:<account_id>
redis-cli DEL "pwd_attempts:ip:203.0.113.7"
```

:::caution
Le compteur par adresse compte chaque mot de passe faux venant d’une
adresse. Une adresse de bureau partagée peut bloquer plusieurs comptes à la
fois par la limite par adresse. La limite ne pose pas d’indicateur de
verrouillage, si bien que le bloc se lève à l’expiration du compteur.
Nettoyez le compteur d’adresse, pas les indicateurs du compte, quand un
réseau est en cause.
:::

### Vérifier le résultat

Connectez-vous comme le compte, ou demandez au titulaire de le faire. La
connexion réussit et les compteurs repartent de zéro.

## Exemple

Révoquez chaque session d’un compte depuis l’API, comme titulaire du compte
ou avec son identifiant :

```sh
curl -k -X DELETE -H "Authorization: Bearer $FACET_API_KEY" \
  -H "X-Requested-With: XMLHttpRequest" \
  "https://facet.localhost:3443/Api/iam/sessions"
```

La réponse donne le nombre : `{"ok": true, "revoked": 3}`. Chaque
session révoquée écrit un événement `session_revoked`. La session courante
survit à l’appel.

## Dépannage

### La connexion répond `429` immédiatement

Le compte ou l’adresse du client est limité. Attendez 5 minutes, ou
nettoyez les clés comme montré ci-dessus.

### Un appareil se déconnecte tout seul

Un autre refresh de la même session a réutilisé un id de refresh périmé. La
session a été supprimée et un événement `refresh_reuse` a été écrit.
Vérifiez le journal des connexions et demandez au titulaire de se
reconnecter.

### Les tokens cessent d’être vérifiés après un redémarrage

`JWT_SIGNING_KEY` n’est pas positionnée ; chaque processus a généré sa
propre clé. Positionnez la variable et redéployez. Chaque titulaire doit se
reconnecter une fois.

### Le journal des connexions ne montre aucune tentative échouée

C’est la conception. Seul le verrouillage écrit une ligne. Lisez le journal
du backend sous `facet.iam.login` pour la trace par tentative.

## Voir aussi

- [Se connecter, MFA, réinitialiser votre mot de passe](/fr/use/first-day/sign-in/) —
  les étapes de connexion et de MFA.
- [Vos paramètres, sessions et clés d’API](/fr/use/account/) —
  la liste de sessions en libre-service.
- [Auditer l’activité](/fr/admin/history/audit/) — le journal des
  connexions.
- [Imposer le MFA](/fr/admin/people/mfa/) — les limites de débit du MFA.
- [Gérer les comptes](/fr/admin/people/accounts/) — les statuts que la
  connexion vérifie.
- Internes sur GitHub :
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
