---
title: Sécurité et gouvernance
description: Comment la sécurité et la gouvernance de Facet protègent l’identité, l’accès, l’historique, les secrets, et où résident vos données.
type: explanation
audience: [evaluator, admin]
features: [IAM-*, RBC-*, AUD-*, DOC-09]
verified_at: eee55a2
sidebar:
  order: 5
---

C’est vous qui devez répondre au questionnaire de sécurité. Cette page donne les réponses de Facet en affirmations courtes : identité, accès, historique, secrets, et localisation des données. Chaque affirmation renvoie à la page qui la montre en pratique. Un point à connaître d’emblée : Facet ne détient aucune certification de sécurité, et cette page ne fait aucune promesse de conformité. Ce que vous pouvez vérifier, c’est ce que fait le produit.

## Identité

- **Un compte par personne.** Les administrateurs créent les comptes ou invitent les personnes par courriel. Il n’y a pas d’inscription publique. Voir [Gérer les comptes](/fr/admin/people/accounts/).
- **Moyens de connexion :** mot de passe, MFA avec une app d’authentification et des codes de secours à usage unique, SSO par OIDC, et clés API pour les programmes. Voir [Exiger la MFA](/fr/admin/people/mfa/) et [Authentification unique (OIDC)](/fr/admin/people/sso/).
- **Vous pouvez exiger la MFA** pour les comptes que vous choisissez.
- **Le verrouillage est automatique.** Dix tentatives de mot de passe échouées depuis un compte le verrouillent, vingt depuis une seule adresse font de même, et les tentatives de MFA se comptent à part. Voir [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/).
- **Les sessions vivent côté serveur, dans Redis.** Un refresh token fonctionne une seule fois ; la réutilisation d’un token ancien tue la session et est enregistrée.
- **Les tokens d’accès sont des JWT signés**, avec un seul algorithme de signature épinglé (ES256).
- **Un journal des connexions** enregistre les connexions, les déconnexions, les verrouillages, et les changements de sécurité comme les mots de passe et les clés. Les refus par les apps et par le SSO sont enregistrés aussi.

## Accès

- **Les règles se rattachent aux rôles.** Chaque rôle porte des lignes de permission. Une ligne nomme une action, un type d’enregistrement, et quelles lignes :

  ```json
  {
    "action": "read",
    "on": "clients.Company",
    "scope": ["$my_clients"]
  }
  ```

  Voir [Rôles et permissions](/fr/admin/people/roles-and-permissions/).
- **Les lignes :** un périmètre filtre les enregistrements qu’un rôle atteint — dans les listes, la recherche, l’API, les apps, et ce que l’assistant peut toucher. Voir [Ne montrer à chaque rôle que ses propres lignes](/fr/admin/people/row-scopes/).
- **Les champs :** une étiquette cache un champ en lecture et refuse l’écriture dedans. Voir [Cacher un champ à certains rôles](/fr/admin/people/hidden-fields/).
- **Un rôle à la fois.** Chaque requête agit sous exactement un rôle ; les rôles ne fusionnent jamais. L’historique reste exact : il montre qui a agi, et sous quel rôle. Voir [Attribuer les rôles](/fr/admin/people/assign-roles/).
- **Aucun pouvoir au-dessus du sien.** Personne ne peut attribuer un rôle au-dessus de son propre niveau, modifier un compte au-dessus de celui-ci, ni élargir un rôle au-delà de ses propres pouvoirs. Voir [Qui peut changer les rôles](/fr/admin/people/who-can-change-roles/).
- **Les apps sont en refus par défaut.** La portée d’une app est l’intersection de ce que l’utilisateur connecté et l’app sont chacun autorisés à faire. Si l’un des deux dit non, la réponse est non. Voir [Contrôler la portée des apps](/fr/admin/apps-access/app-grants/).
- **Les appels sans authentification sont presque sans pouvoir.** Ils tournent sous un seul rôle `anonymous`, modifiable, avec presque aucun droit par défaut. Supprimez ce rôle, et les appels sans authentification répondent `401`.

## Historique

- **Chaque changement est enregistré** : qui l’a fait, quand, par quelle app. Cela couvre les modifications normales, l’automatisation, et les changements de l’assistant. Voir [Voir qui a fait quoi](/fr/admin/history/audit/).
- **Caviardage.** Les réponses d’audit marquent ce qu’elles ont caché à l’appelant ; les valeurs sensibles restent cachées à toute personne qui n’a pas le droit de les voir.
- **Retour arrière.** Un document peut revenir à un état antérieur. Un retour arrière peut aussi restaurer un document supprimé. Voir [Revenir en arrière](/fr/admin/history/roll-back/).
- **Le journal est borné, à votre choix.** Vous fixez la durée de conservation de l’historique complet — 180 jours par défaut. L’historique plus ancien se replie en instantanés, et le retour arrière atteint aussi loin que la fenêtre. Voir [Rétention : ce qui est conservé](/fr/admin/history/retention/).

## Secrets

- **Un champ marqué secret ne se trouve jamais dans le document ni dans l’historique.** Le client dépose la valeur une seule fois ; Facet la stocke à part, hachée (bcrypt pour les mots de passe) ou chiffrée (AES-256-GCM). Voir [Champs secrets et champs en écriture seule](/fr/build/model/data/secret-fields/).
- **Aucun chemin de lecture ne renvoie une valeur secrète** — ni HTTP, ni scripts, ni exports, ni copies. Les consommateurs la vérifient ou la révèlent côté serveur seulement.
- **Les champs en écriture seule** acceptent une entrée et ne sont jamais stockés avec le document, donc ils n’apparaissent jamais dans les lectures ni dans l’historique.

## Où résident vos données

- **Dans votre PostgreSQL et votre stockage de fichiers, où que vous exécutiez Facet.** Rien ne sort, sauf si vous l’y envoyez. Les fichiers se posent sur un disque local ou un stockage compatible S3 que vous configurez. Voir [Stockage de fichiers](/fr/admin/configure/file-storage/).
- **Un fichier de configuration par environnement.** Les valeurs secrètes peuvent venir de variables d’environnement plutôt que du fichier. Voir [Fichiers de configuration](/fr/admin/configure/configuration-files/).
- **Les horodatages sont stockés en UTC.**

## L’exploiter vous-même

Facet est un logiciel à auto-héberger : ce sont vos serveurs. La pile de conteneurs publiée compte cinq services — PostgreSQL, Redis, le backend, le frontend, et une terminaison TLS — et un déploiement depuis le code source fonctionne aussi. Voir [Déployer avec des conteneurs](/fr/admin/install/containers/) et [Déployer en production](/fr/admin/install/production/).

:::tip
Emmenez cette page à la revue de sécurité. Chaque affirmation renvoie à la page qui montre la pratique, et les contrats d’ingénierie derrière elles se trouvent dans le dépôt, sous `doc/backend/` — votre auditeur peut lire [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md), et [secrets.md](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md).
:::

## Voir aussi

- [Le tableau d’ensemble](/fr/discover/how-it-works/) — où les contrôles se situent dans le chemin d’une requête.
- [Rôles et permissions](/fr/admin/people/roles-and-permissions/) — le modèle d’accès en pratique.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — la piste d’audit au quotidien.
- [Licence et services](/fr/discover/licensing-and-services/) — la licence derrière les liens source ci-dessus.
