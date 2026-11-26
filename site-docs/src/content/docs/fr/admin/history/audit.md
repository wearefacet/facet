---
title: Auditer l’activité
description: "Lisez le journal des mutations par l’API et l’interface admin, et consultez le journal des connexions."
audience: [admin]
features: [AUD-02, AUD-08, IAM-13, FE-16]
sidebar:
  order: 10
verified_at: a8e1b43
---

Facet enregistre chaque create, update, delete et instantané dans un journal
en ajout seul. Chaque ligne énonce qui a fait le changement, ce qui a
changé, quand, et ce qui l’a causé. Cette page montre comment lire le
journal, et comment lire à côté le journal des événements de connexion.

## Quand l’utiliser

- Vous devez répondre qui a changé un document, et quand.
- Vous enquêtez sur un incident à travers plusieurs documents.
- Vous révisez les événements de connexion et de sécurité.

## Avant de commencer

- **L’historique du document.** Il demande des droits de lecture sur le
  document cible.
- **Le journal global.** Il demande une lecture en joker sur `*.*`, une
  ligne qui couvre chaque doctype.
- **Le modèle.** Voir [Le journal des mutations](/fr/admin/under-the-hood/change-log/)
  pour ce que porte une ligne.

## Étapes

### 1. Lire l’historique d’un document

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee/01J8Z0A7G3Q5M2X9K4T6VBNR8D/history"
```

La réponse liste les changements du document, du plus récent au plus
ancien. Chaque ligne porte l’action, l’acteur, l’heure, et le contenu ou le
diff.

### 2. Fondre les documents enfants dans la chronologie

Ajoutez `?include=children` pour replier l’historique des enfants de
composition dans la chronologie du parent :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee/01J8Z0A7G3Q5M2X9K4T6VBNR8D/history?include=children"
```

Chaque branche enfant est filtrée par le périmètre de lignes propre à

l’enfant. Un enfant que vous ne pouvez pas lire ne répond pas `403` — sa
branche disparaît.

### 3. Chercher dans toute l’organisation

Le journal global liste chaque mutation. Les filtres voyagent dans la forme
crochets :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/Audit?filters[action__eq]=delete&filters[domain__eq]=hr"
```

La réponse liste chaque delete du domaine `hr`, avec un nombre plafonné de
lignes et un indicateur `more` pour la pagination. Une clé de requête nue comme
`?doc_type=Invoice` répond `422` — la grammaire n’admet que la forme
crochets. Les scripts peuvent envoyer la méthode HTTP `QUERY` à la place,
avec les paramètres de liste dans un corps JSON :
`{"filters": {"action__eq": "delete"}}`. Sous cette forme, tout paramètre
de chaîne de requête répond `422`.

### 4. Utiliser l’interface admin

Ouvrez **Configurer → Journal d’audit**. Le tableau liste chaque mutation de
tous les domaines. Ajoutez des filtres pour domaine, doctype, action,
acteur, canal, ou heure. Sélectionnez une ligne pour examiner les champs
changés, l’acteur, le canal, et la cause. Depuis cet écran, un
administrateur peut aussi ramener un document en arrière — voir
[Revenir en arrière](/fr/admin/history/roll-back/).

### 5. Lire le journal des connexions

Les événements de connexion sont des documents du doctype `iam.LoginEvent`.
Un rôle avec des droits de lecture dessus les liste par l’API de document
standard :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/LoginEvent?items=20&sort=-created_at"
```

Chaque ligne porte le type d’événement, l’id du compte, et des détails
comme l’adresse du client.

## Explication

### Ce que chaque ligne enregistre

| Question  | Champs                                                              |
| --------- | --------------------------------------------------------------------- |
| Qui       | `actioner_id`, `channel`, `app`, `api_key`, `acting_role`             |
| Quoi      | le contenu (create, instantané, delete) ou le diff (update)           |
| Quand     | `emitted_at`                                                          |
| Pourquoi  | `cause_kind`, `cause_name`, `cause_event`, `cause_parent`, `cause_trace` |

Les champs de cause forment une chaîne. Chaque ligne nomme sa ligne parente
dans `cause_parent` ; une seule marche reconstruit toute l’histoire. Toutes
les lignes d’un cluster partagent l’id racine dans `cause_trace` ; une
requête renvoie le cluster.

### Les deux modes de lecture

- **L’historique du document.** La barrière de lecture du document cible
  s’applique. Un appelant sans droit de lecture du tout sur le doctype
  répond `403`. Un appelant qui ne peut pas voir ce document précis répond
  le même `404` qu’un document manquant.
- **Le journal global.** Une lecture en joker sur `*.*` est exigée.
  `domain` et `doc_type` agissent comme filtres, jamais comme barrières —
  un appel demande ce qui a changé dans un domaine.

### Les filtres

| Champ                                                        | Opérateurs    |
| ------------------------------------------------------------- | --------------- |
| `domain`, `doc_type`, `doc_id`                                | `eq`            |
| `action`, `actioner_id`, `app`, `channel`, `kind`, `trace`    | `eq`, `ne`      |
| `emitted_at`                                                  | `gte`, `lte`    |

`kind` filtre par genre de cause, par exemple `action`, `hook_event`,
`rollback` ou `assistant`. `trace` prend un id racine de cluster.

### Les canaux

| Canal          | Signification                                     |
| --------------- | --------------------------------------------------- |
| `session`       | Une session navigateur connectée                    |
| `oauth_app`     | Un token d’app issu d’une connexion OAuth           |
| `app_api_key`   | Une clé d’API possédée par une app                  |
| `api_key`       | Une clé d’API statique                              |
| `mcp`           | Une session d’agent MCP                             |
| `internal`      | Travail du système : passes de cron, compactage, déclencheurs |

### Le caviardage

Les valeurs que votre rôle ne peut pas voir sont retirées de la réponse du
journal, et le bloc `redacted` nomme les chemins. Voir
[Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/).

### Le journal des connexions

Les lignes `iam.LoginEvent` enregistrent chaque événement d’authentification :
connexion, déconnexion, réutilisation de refresh, verrouillage, enrôlement
et changements MFA, réinitialisation de mot de passe, invitations,
consentements accordés, révocations de clés d’API et de sessions, connexions
OIDC, et refus. Deux limites importent aux relecteurs. Les tentatives de mot
de passe échouées isolées ne sont pas journalisées — seul le verrouillage
l’est. Les refresh réussis ne sont pas journalisés non plus — ils tournent
à l’horloge et noieraient le journal. Le journal du backend porte chaque
tentative échouée et chaque refresh réussi, avec l’id du compte et l’adresse
du client.

## Dépannage

### L’API répond `422 Unknown parameter`

Une clé de requête nue n’est pas dans la grammaire. Enveloppez le filtre
dans la forme crochets, ou envoyez le corps `QUERY`.

### Le journal global répond `403`

Votre rôle actif n’a pas la lecture en joker sur `*.*`. Basculez vers un
rôle qui la porte.

### Une ligne d’historique n’affiche pas de valeur

Du caviardage pour votre rôle — voir
[Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/).

### Un changement récent manque

Le journal garde les lignes à l’intérieur de la fenêtre de rétention. Les
lignes plus anciennes se replient en un instantané par document — voir
[La rétention](/fr/admin/history/retention/).

## Voir aussi

- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — le modèle de
  données derrière cette page.
- [Revenir en arrière](/fr/admin/history/roll-back/) — annuler depuis le
  journal.
- [La rétention](/fr/admin/history/retention/) — combien de temps le journal garde
  les lignes.
- [Historique et annulation](/fr/use/documents/history-undo/) — la surface par
  document dans l’app.
- Internes sur GitHub :
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
