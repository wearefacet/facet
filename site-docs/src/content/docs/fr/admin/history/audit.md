---
title: Voir qui a fait quoi
description: "Lisez le journal d’audit : l’historique d’un document, tous les changements depuis un seul endroit, et le journal des connexions."
type: how-to
audience: [admin]
features: [AUD-02, AUD-08, IAM-13, FE-16]
verified_at: eee55a2
sidebar:
  order: 0
---

Un client appelle Brightwater : quelqu’un a déplacé notre réservation au
mardi. Ravi a besoin d’une réponse, preuve à l’appui, en une minute. Facet
enregistre chaque create, update, delete et instantané dans un journal en
ajout seul. Chaque ligne énonce qui a fait le changement, ce qui a changé,
quand, et ce qui l’a causé. Le journal répond pour un document, ou pour
toute l’organisation d’un coup. Un second journal enregistre les connexions.

## Quand l’utiliser

- Vous devez dire qui a changé un document, et quand.
- Vous enquêtez sur un incident à travers plusieurs documents.
- Vous relisez les événements de connexion et de sécurité.

## Avant de commencer

- **L’historique du document.** Il demande des droits de lecture sur le
  document cible.
- **Le journal global.** Il demande une lecture en joker sur `*.*` — une
  ligne de permission qui couvre chaque doctype.
- **Le modèle.** [Le journal des mutations](/fr/admin/under-the-hood/change-log/)
  explique ce que porte une ligne.

## Étapes

### 1. Lire l’historique d’un document

Chaque document expose son propre passé sur la route d’historique :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/equipment/Item/EQ-2026-0004/history"
```

La réponse liste les changements du document, du plus récent au plus
ancien. La tente Pagoda de Brightwater montre deux lignes — son create, et
l’update que l’app de check-out a écrit quand Lucía l’a rendue :

```json
{
  "id": "06H1GDBJBWDP6SE85NVRFJ9A15",
  "domain": "equipment",
  "doc_type": "Item",
  "doc_id": "EQ-2026-0004",
  "idx": 3,
  "action": "update",
  "actioner_id": "06H1FKZGAC2CA2JYPC97DKXD3Z",
  "arguments": {
    "diff": {
      "set": [{"path": ["status"], "value": "available"}],
      "unset": []
    },
    "meta_diff": {"set": [], "unset": []}
  },
  "redacted": [],
  "channel": "oauth_app",
  "app": "06H1GCMXX4HX02S6ZVDGJ3SQ3P",
  "api_key": null,
  "acting_role": "iam.Roles.warehouse",
  "cause_kind": "request",
  "cause_name": null,
  "cause_event": null,
  "cause_source": null,
  "cause_parent": null,
  "cause_trace": "06H1GDBJBWDP6SE85NVRFJ9A15",
  "emitted_at": "2026-11-26T14:14:45Z",
  "display_name": null
}
```

Lisez la ligne comme une phrase : le compte de Lucía, agissant comme
*Warehouse*, par l’app de check-out, a mis `status` à `available` à 14:14.
Un create ou un delete porte le contenu complet dans `arguments` ; un
update porte la différence.

### 2. Fusionner les documents enfants dans la chronologie

Ajoutez `?include=children` pour replier l’historique des enfants de
composition dans la chronologie du parent :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/equipment/Item/EQ-2026-0004/history?include=children"
```

Chaque branche enfant est filtrée par le périmètre de lignes propre à
l’enfant. Un enfant que vous ne pouvez pas lire ne répond pas `403` — sa
branche sort de la chronologie.

### 3. Chercher dans toute l’organisation

Le journal global liste chaque changement. Les filtres voyagent dans la
forme crochets :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/Audit?filters[action__eq]=delete&filters[domain__eq]=iam"
```

La réponse liste chaque delete du domaine `iam`, avec un total plafonné et
un indicateur `more` pour la pagination. Le total s’arrête à 1 000 ; `more`
vaut `true` quand le total réel était plus haut. Une clé de requête nue
comme `?doc_type=Company` répond `422` — la grammaire n’admet que la forme
crochets :

```json
{"error": "Unknown parameter 'doc_type' (accepted: page, items, sort, filters)"}
```

Les scripts peuvent envoyer la méthode `QUERY` à la place, avec les
paramètres de liste dans un corps JSON :
`{"filters": {"action__eq": "delete"}}`. Sous cette forme, tout paramètre
de chaîne de requête répond `422`.

### 4. Utiliser l’interface admin

Ouvrez **Configurer → Journal d’audit**. Le tableau liste chaque changement
de tous les domaines. Ajoutez des filtres pour domaine, doctype, action,
acteur, canal ou heure. Sélectionnez une ligne pour examiner les champs
changés, l’acteur, le canal et la cause. Depuis cet écran, un
administrateur peut aussi ramener un changement en arrière — voir
[Revenir en arrière](/fr/admin/history/roll-back/).

### 5. Lire le journal des connexions

Les événements de connexion sont des documents du doctype
`iam.LoginEvent`. Un rôle avec des droits de lecture dessus les liste par
l’API de document standard :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/iam/LoginEvent?items=20&sort=-created_at"
```

Chaque ligne porte le type d’événement, l’id du compte, et des détails
comme le rôle élu :

```json
{"event": "login", "details": "Role: iam.Roles.admin", "account_id": "06H1FKW9RRQX860BKXRBY3YT8V"}
```

## Explication

### Ce que chaque ligne enregistre

| Question | Champs |
| --- | --- |
| Qui | `actioner_id`, `channel`, `app`, `api_key`, `acting_role` |
| Quoi | le contenu (create, instantané, delete) ou le diff (update) |
| Quand | `emitted_at` |
| Pourquoi | `cause_kind`, `cause_name`, `cause_event`, `cause_parent`, `cause_trace` |

Les champs de cause forment une chaîne. Chaque ligne nomme sa ligne parente
dans `cause_parent`, si bien qu’une seule marche reconstruit toute
l’histoire. Toutes les lignes d’un cluster partagent l’id racine dans
`cause_trace`, si bien qu’une requête renvoie le cluster.

### Les deux modes de lecture

- **L’historique du document.** Le garde-fou de lecture du document cible
  s’applique. Un appelant sans aucun droit de lecture sur le doctype répond
  `403`. Un appelant qui ne peut pas voir ce document précis répond le même
  `404` qu’un document manquant.
- **Le journal global.** Une lecture en joker sur `*.*` est exigée.
  `domain` et `doc_type` agissent comme filtres, jamais comme garde-fous —
  un appel demande ce qui a changé dans un domaine. Un appelant connecté
  par un token d’app ou une clé possédée par une app est refusé ici, quel
  que soit son rôle. Une attribution nomme un domaine, si bien qu’aucune
  attribution ne peut couvrir une vue sur tous les domaines.

### Les filtres

| Champ | Opérateurs |
| --- | --- |
| `domain`, `doc_type`, `doc_id` | `eq` |
| `action`, `actioner_id`, `app`, `channel`, `kind`, `trace` | `eq`, `ne` |
| `emitted_at` | `gte`, `lte` |

`kind` filtre par genre de cause, par exemple `request`, `action`,
`assistant`, `rollback` ou `compaction`. `trace` prend un id racine de
cluster, si bien qu’une requête renvoie un incident.

### Les canaux

| Canal | Signification |
| --- | --- |
| `session` | Une session navigateur connectée |
| `oauth_app` | Un token d’app issu d’une connexion OAuth |
| `app_api_key` | Une clé d’API possédée par une app |
| `api_key` | Une clé d’API statique |
| `mcp` | Une session d’agent MCP |
| `internal` | Travail du système : passes de cron, compactage, déclencheurs |

### Le caviardage

Les valeurs que votre rôle ne peut pas voir sont retirées de la réponse du
journal, et le bloc `redacted` nomme les chemins retirés. Le journal stocké
garde les valeurs — le retrait se fait à la lecture, pour chaque appelant.
Voir [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/).

### Le journal des connexions

Les lignes `iam.LoginEvent` enregistrent les événements d’authentification :
connexion, déconnexion, verrouillage, réutilisation de refresh, enrôlement
et changements MFA, réinitialisation de mot de passe, invitations,
consentements accordés, révocations de clés d’API et de sessions,
connexions OIDC, et refus d’app ou SSO. Deux limites importent aux
relecteurs. Les tentatives de mot de passe échouées isolées ne sont pas
journalisées — seul le verrouillage l’est. Les refresh réussis ne sont pas
journalisés non plus — ils tournent à l’horloge et noieraient le journal.
Le journal du backend porte chaque tentative échouée et chaque refresh
réussi, avec l’id du compte et l’adresse du client.

## Dépannage

### L’API répond `422 Unknown parameter`

Une clé de requête nue n’est pas dans la grammaire. Enveloppez le filtre
dans la forme crochets, ou envoyez le corps `QUERY`.

### Le journal global répond `403`

Votre rôle actif n’a pas la lecture en joker sur `*.*`, ou vous avez
appelé par un token d’app — les apps ne peuvent pas lire le journal global.
Basculez vers une session navigateur ou une clé d’API statique avec un rôle
qui porte la ligne.

### Une ligne d’historique n’affiche pas de valeur

Du caviardage pour votre rôle — voir
[Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/).

### Un changement récent manque

Le journal garde les lignes à l’intérieur de la fenêtre de rétention. Les
lignes plus anciennes se replient en un instantané par document — voir
[Rétention : ce qui est gardé](/fr/admin/history/retention/).

## Voir aussi

- [Revenir en arrière](/fr/admin/history/roll-back/) — annuler depuis le
  journal.
- [Rétention : ce qui est gardé](/fr/admin/history/retention/) — combien de
  temps le journal garde les lignes.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — le
  modèle de données derrière cette page.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — la
  surface par document dans l’app.
- Internes sur GitHub :
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Sécurité et gouvernance](/fr/discover/security/)
