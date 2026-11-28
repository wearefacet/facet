---
title: Revenir en arrière
description: Ramenez un document à un état antérieur, restaurez un document supprimé, et connaissez les limites.
type: how-to
audience: [admin]
features: [AUD-04]
verified_at: eee55a2
sidebar:
  order: 1
---

Nadia enregistre une fiche société avec les prix du trimestre dernier par
erreur, et la valeur fausse est déjà dans l’espace de travail. Un retour
arrière remet les choses en ordre : Facet rejoue l’historique du document
jusqu’au changement que vous nommez, et enregistre le résultat comme un
nouvel instantané. Une restauration ramène un document supprimé de la même
façon. Les deux écrivent de nouvelles lignes d’historique ; rien n’est
effacé.

## Quand l’utiliser

- Une édition fausse a changé un document.
- Un document a été supprimé par erreur.
- Vous devez annuler un changement et garder le reste.

## Avant de commencer

- **Le droit.** Il vous faut le droit `update` sur le document cible.
- **L’id cible.** Trouvez-le dans l’historique du document ou le journal
  global — voir [Voir qui a fait quoi](/fr/admin/history/audit/).
- **La fenêtre.** La cible doit se trouver à l’intérieur de la fenêtre de
  rétention — voir [Rétention : ce qui est gardé](/fr/admin/history/retention/).

## Étapes

### 1. Trouver le changement cible

Ouvrez l’historique du document. Chaque entrée montre son id — un ULID de
26 caractères. Copiez l’id du changement vers lequel vous voulez revenir.
Par exemple, la ligne de create de Maison Lumière est
`06H1FM1B3MWR784V64VP6QFM94`. Un id mal formé répond `422` avant que quoi
que ce soit ne tourne :

```json
{"error": "mutation_id must be a ULID"}
```

### 2. Ramener le document en arrière

La route du document prend la cible dans le corps :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"mutation_id": "06H1FM1B3MWR784V64VP6QFM94"}' \
  "$(facet-cli host)/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154/rollback"
```

Le corps porte `mutation_id`, l’id du changement cible ; l’URL porte l’id
du document. La réponse est le document dans son état ramené en arrière :

```json
{
  "data": {
    "city": "Lyon",
    "name": "Maison Lumière",
    "account_manager": "iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE"
  },
  "meta": {
    "id": "06H1FM1B3MXBPS0JYVM3BDD154",
    "uri": "urn:facet:clients:Company:06H1FM1B3MXBPS0JYVM3BDD154",
    "mid": "06H1GDBJBWDP6SE85NVRFJ9A15",
    "domain": "clients",
    "doc_type": "Company",
    "version": 1,
    "schema_version": 1,
    "display_name": "Maison Lumière",
    "created_at": "2026-11-26T12:24:08Z",
    "updated_at": "2026-11-26T12:24:09Z"
  },
  "cascade_restored": []
}
```

`meta.mid` est le nouveau changement d’instantané — le retour arrière
lui-même. `cascade_restored` liste les enfants qu’une restauration a
ramenés ; un retour arrière simple renvoie un tableau vide. La route
globale `POST /Api/Audit/<mutation id>/rollback` fait la même chose depuis
le seul journal global. Son corps `404` nomme la fenêtre de base, parce que
la route ne connaît pas le doctype cible.

### 3. Restaurer un document supprimé

La route de restauration résout la cible toute seule. Le corps est vide :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" -d '{}' \
  "$(facet-cli host)/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154/restore"
```

| Réponse | Signification |
| --- | --- |
| `200` | Le document est de nouveau vivant. |
| `404` | Le document n’a pas d’historique à restaurer. |
| `409` | Le document n’est pas supprimé. Rechargez plutôt que de réessayer. |
| `403` | Votre rôle n’a pas `update` sur le document. |
| `422` | Historique dégénéré : une suppression sans changement avant elle. |

## Explication

### Ce qu’écrit un retour arrière

Le service rejoue l’historique jusqu’à la cible et persiste un nouveau
changement `snapshot`. L’instantané enregistre votre id de compte comme
acteur. Les appelants internes enregistrent `system:rollback`. Son
`cause_kind` est `rollback`, et son `cause_parent` nomme le changement
cible, si bien que la piste d’audit relie l’instantané à la cible exacte.
Chaque retour arrière démarre un cluster causal neuf — l’id propre de
l’instantané est son `cause_trace`.

### Les limites

- **La profondeur du retour arrière égale la fenêtre de rétention.** La
  passe de compactage quotidienne remplace les lignes plus anciennes par
  un instantané par document. Une cible plus ancienne que la fenêtre
  répond `404`, et le corps nomme la fenêtre effective. Les routes
  document, enfant et restauration nomment la fenêtre pour ce doctype ; la
  route globale nomme la fenêtre de base. Une fenêtre de `0` signifie
  l’historique complet.
- **Un retour arrière vers un delete restaure le document.** La cible se
  résout au changement immédiatement avant le delete. L’instantané efface
  le marqueur de suppression, et le document est de nouveau vivant.
- **Un delete sans changement avant lui n’a rien à restaurer.** La requête
  répond `422`.

### Les enfants reviennent avec le document

Une restauration ramène aussi les enfants de composition que le delete
annulé avait retirés. La pré-vérification contrôle chaque enfant avant
toute écriture ; un seul refus avorte toute la restauration, et rien ne
change. Chaque enfant reçoit son propre changement d’instantané.
Restaurer la réservation supprimée `BK-2026-0001` ramènerait ses cinq
lignes de réservation, et la réponse les liste dans `cascade_restored` :

```json
"cascade_restored": [
  {
    "domain": "rentals",
    "doc_type": "BookingLine",
    "doc_id": "06H1FM1D68H020ZFQ3MKCWY0EE",
    "mut_id": "06H1FM1D68GR9DRWA65NZ968ZR"
  }
]
```

Un enfant recréé ou resupprimé après le delete annulé reste intact — la
restauration n’atteint que les enfants pour lesquels le delete en cascade
est encore le dernier changement.

### Qui peut revenir en arrière

L’appelant demande `update` sur le document. Deux garde-fous de transition
peuvent encore refuser avec `403` :

- Le garde-fou d’autorité des rôles refuse un retour arrière qui
  ressusciterait un état d’identité plus fort, par exemple une ancienne
  affectation du rôle administrateur.
- Le garde-fou de visibilité des champs refuse un retour arrière qui
  rembobinerait une valeur dans un champ que votre rôle ne peut pas voir —
  même quand le changement cible ne touchait que des champs visibles.

:::caution[Le document prend tout le contenu de la cible]
Le document prend tout le contenu de l’état cible. Les changements faits
après la cible quittent le document. Ils restent dans l’historique.
Choisissez une cible plus tardive et revenez en arrière une seconde fois
pour y retourner.
:::

## Dépannage

### Le retour arrière répond `404` et nomme une fenêtre

La cible est plus ancienne que la fenêtre de rétention, inconnue, ou
repliée par la fusion à l’écriture. Un appel refusé sur l’instance
Brightwater renvoie :

```json
{"error": "Mutation 01ARZ3NDEKTSV4RRFFQ69G5FAV not found. It may be unknown, older than the retention window (180 days for clients.Company), or folded by coalescing."}
```

Choisissez une cible plus récente, ou élargissez la fenêtre avant la
prochaine passe de compactage — voir
[Rétention : ce qui est gardé](/fr/admin/history/retention/).

### Le retour arrière répond `422` pour un id bien formé

L’id peut nommer un delete sans changement avant lui, ou un changement que
la fusion à l’écriture a replié — voir
[Rétention : ce qui est gardé](/fr/admin/history/retention/).

### Le retour arrière répond `403`

Il vous manque `update` sur le document, ou un garde-fou de transition a
refusé le résultat. Vérifiez votre rôle actif et les étiquettes des champs
rembobinés.

### La restauration répond `409`

Le document est vivant. Rechargez-le plutôt que de réessayer.

## Voir aussi

- [Voir qui a fait quoi](/fr/admin/history/audit/) — trouver le changement
  cible.
- [Rétention : ce qui est gardé](/fr/admin/history/retention/) — pourquoi
  la profondeur égale la fenêtre.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — ce
  qu’est une ligne d’instantané.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — la
  surface d’annulation pour l’utilisateur final.
- Internes sur GitHub :
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Documents : des enregistrements avec une mémoire](/fr/discover/how-it-works/documents/)
