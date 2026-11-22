---
title: Sécurité et gouvernance
description: Comment Facet protège l’identité, l’accès, l’audit, les secrets, et où résident vos données.
audience: [evaluator]
features: [IAM-*, RBC-*, AUD-*, DOC-09]
sidebar:
  order: 4
verified_at: f1409cdc
---

Utilisez cette page pour une revue de sécurité ou un audit. Elle résume le
modèle de gouvernance : identité, permissions, lectures sans divulgation,
audit, secrets, et localisation des données.

## Identité

- **Les comptes sont des documents.** Un compte est un document `iam.Account`,
  et ses changements sont audités comme tous les autres.
- **Moyens de connexion :** mot de passe, MFA TOTP (mots de passe à usage
  unique basés sur le temps, avec codes de secours à usage unique), SSO via
  OIDC, et clés d’API statiques.
- **Verrouillage après des échecs répétés.** Des échecs de connexion répétés
  verrouillent le compte. La limitation compte les tentatives de mot de
  passe, par IP et de MFA.
- **Sessions côté serveur.** Les sessions vivent côté serveur dans Redis. Les
  refresh tokens tournent à chaque usage. La réutilisation d’un ancien token
  tue la session et atterrit dans le journal des connexions.
- **Tokens signés.** Les tokens d’accès sont des JWT signés avec un algorithme
  de signature épinglé (ES256).
- **Un journal des connexions.** Chaque événement d’authentification —
  connexion, déconnexion, refus, refresh — atterrit dans un journal
  d’événements de connexion en ajout seul.

## Permissions

Les rôles sont des documents (`iam.Roles`). Chaque rôle porte un niveau de 0
à 100 et une liste de lignes de permission. Une ligne de permission a cette
forme :

```json
{
  "action": "read",
  "on": "production.Project",
  "scope": ["$mine", "$global"]
}
```

- `action` — `read`, `create`, `update`, `delete`, `*`, ou une action nommée.
- `on` — un chemin de doctype comme `production.Project`. Des jokers existent
  pour les rôles admin.
- `scope` — des prédicats de lignes nommés que le doctype déclare (`$mine`,
  `$global`, ou l’un des vôtres). Une liste donne les lignes qui répondent à

  l’un d’eux.
- `except` — des chemins soustraits de la ligne. Facultatif : une ligne sans
  lui atteint tous les chemins que son `on` couvre.

Les contrôleurs appliquent ces règles dans la couche de données — dans
PostgreSQL, pas dans votre application :

- **Un rôle par requête.** Un rôle élu par requête. Les rôles ne fusionnent
  jamais.
- **Les périmètres deviennent du SQL.** Les périmètres de lignes se compilent
  en SQL. Une liste ne renvoie que les lignes que le rôle peut voir.
- **Les étiquettes de champs.** Elles cachent les champs invisibles en
  lecture et refusent de les écrire.
- **Pas de pouvoir au-dessus du sien.** Règles d’autorité des rôles : un
  appelant ne peut pas attribuer un rôle au-dessus de son niveau, ni modifier
  un compte au-dessus de son niveau, ni élargir un rôle au-del à de ses
  propres pouvoirs.
- **Les applications, double contrôle.** Les applications agissent à la fois
  sous leur attribution et sous le rôle élu. Si un contrôle ne passe pas,
  l’accès est refusé.
- **Anonymous aussi.** Les requêtes sans identifiant tournent sous un rôle
  modifiable, `anonymous`. Ses droits de lecture couvrent toute la surface
  publique. Supprimez ce rôle, et ces requêtes répondent `401` — le refus par
  défaut.

## Lectures sans divulgation

Le contrôle d’accès ne doit pas révéler quels documents existent :

- Une lecture individuelle refusée répond le même `404` qu’un document
  manquant.
- Une liste refusée tourne avec un prédicat toujours faux. L’appelant reçoit
  `200` sans aucune ligne.
- Une lecture d’enfant vérifie d’abord la barrière de lecture du parent. Un
  refus donne le même `404` sans divulgation.

## Audit

- **Chaque écriture est enregistrée.** Le journal des mutations enregistre
  chaque create, update, delete et instantané : l’acteur, le canal (session,
  app OAuth, clé d’API, MCP), l’application, le changement, l’heure et la
  chaîne de cause.
- **Historique par document, ou sur toute l’organisation.** Lisez l’historique
  par document. Avec des droits de lecture en joker, listez les changements
  de toute l’organisation en un appel.
- **Caviardage.** Les réponses d’audit marquent les chemins de contenu
  qu’elles ont retirés pour l’appelant dans un bloc de métadonnées
  `redacted`. Les arguments sensibles restent cachés aux appelants qui n’ont
  pas le droit de les voir.
- **Retour arrière.** Ramenez un document à n’importe quel état antérieur. Un
  retour arrière vers un delete restaure le document. Les documents
  supprimés se restaurent aussi directement.
- **Un journal borné.** Le journal se compacte après la fenêtre de rétention
  (180 jours par défaut). La profondeur du retour arrière égale cette
  fenêtre.

## Secrets et champs en écriture seule

- **Les secrets restent hors des documents.** Un champ `secret` garde les
  valeurs hors des documents et hors du journal des mutations. Le client
  dépose une valeur avec un identifiant à usage unique. L’écriture stocke un
  marqueur. La valeur est hachée (bcrypt pour les mots de passe) ou chiffrée
  (AES-256-GCM) dans une table à part.
- **Aucun chemin de lecture ne renvoie un secret.** Aucun chemin — HTTP, MCP,
  scripts Lua, export, copie — ne peut renvoyer une valeur secrète. Les
  consommateurs la vérifient ou la révèlent côté serveur seulement.
- **Champs en écriture seule.** Un champ `write_only` accepte une entrée et
  laisse les scripts le lire. Facet le retire avant de stocker le document.
  Il n’apparaît jamais dans les lectures ni dans l’historique.

## Où résident vos données

- **Sur vos serveurs.** Facet est un logiciel à auto-héberger. Ce sont vos
  serveurs. Les données restent dans votre PostgreSQL, votre Redis et votre
  stockage d’objets (fichiers et pièces jointes).
- **Un fichier de configuration par environnement.** La configuration tient
  dans un fichier YAML par environnement. Les valeurs secrètes peuvent venir
  de variables d’environnement plutôt que du fichier.
- **Horodatage en UTC.** Les timestamps sont stockés en UTC.

:::tip
Emmenez cette page à la revue de sécurité. Chaque section correspond à un
document de conception dans le dépôt ; votre auditeur lit le contrat
d’implémentation, pas un résumé.
:::

## Voir aussi

- [Architecture en un coup d’œil](/fr/start/architecture/) — où le contrôle se situe dans le chemin d’une requête.
- [Gouverner l’accès](/fr/govern/) — les guides admin pour les comptes, les rôles et le SSO.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md), [secrets.md](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md).
