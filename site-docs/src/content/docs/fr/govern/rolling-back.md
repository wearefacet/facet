---
title: Revenir en arrière
description: "Ramenez un document à une mutation antérieure, restaurez un document supprimé, et connaissez les limites."
audience: [admin]
features: [AUD-04]
sidebar:
  order: 11
verified_at: fd345fe3
---

Un retour arrière rejoue l’historique des changements d’un document
jusqu’à une mutation choisie, et enregistre le résultat comme un nouvel
instantané. Une restauration ramène un document supprimé. Les deux écrivent
de nouvelles lignes d’historiqueà ; rien n’est effacé.

## Quand l’utiliser

- Une édition en masse erronée a changé un document.
- Un document a été supprimé par erreur.
- Vous devez annuler un changement et garder le reste.

## Avant de commencer

- **Le droit.** Il vous faut le droit `update` sur le document cible.
- **L’id cible.** Trouvez-le sur la page d’historique du document ou le
  journal d’audit global — voir
  [Auditer l’activité](/fr/govern/auditing-activity/).
- **La fenêtre.** La cible doit se trouver à l’intérieur de la fenêtre de
  rétention — voir [La rétention](/fr/govern/retention/).

## Étapes

### 1. Trouver la mutation cible

Ouvrez l’historique du document. Chaque entrée montre son id de mutation —
un ULID de 26 caractères. Copiez l’id du changement vers lequel vous voulez
revenir. Un id mal formé répond `422` avant que le service ne tourne.

### 2. Ramener le document en arrière

La route du document prend la cible dans le corpsà :

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mutation_id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D"}' \
  "https://facet.localhost:3443/Api/production/Project/01HXQ5M2X9K4T6VBNR8D3Q5M2X/rollback"
```

Le corps porte `mutation_id`, l’id du changement cibleà ; l’URL porte l’id
du document. La réponse est le document dans son état ramené en arrièreà :

```json
{
  "data": {
    "name": "Aurora launch",
    "status": "planned"
  },
  "meta": {
    "id": "01HXQ5M2X9K4T6VBNR8D3Q5M2X",
    "uri": "urn:facet:production:Project:01HXQ5M2X9K4T6VBNR8D3Q5M2X",
    "mid": "01CRT6VBNR8D3Q5M2X7BQ5M2XA",
    "domain": "production",
    "doc_type": "Project",
    "version": 7,
    "schema_version": 1,
    "display_name": "Aurora launch",
    "created_at": "2026-01-12T09:30:00Z",
    "updated_at": "2026-11-13T10:15:00Z"
  },
  "cascade_restored": []
}
```

`meta.mid` est la nouvelle mutation d’instantané. `cascade_restored` liste
les enfants qu’une restauration a ramenésà ; un retour arrière simple
renvoie un tableau vide. La route globale
`POST /Api/Audit/<mutation id>/rollback` fait la même chose depuis le seul
journal global. Son corps `404` nomme la fenêtre de base, parce que la
route ne connaît pas le doctype cible.

### 3. Restaurer un document supprimé

La route de restauration résout la cible toute seule. Le corps est videà :

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" -d '{}' \
  "https://facet.localhost:3443/Api/production/Project/01HXQ5M2X9K4T6VBNR8D3Q5M2X/restore"
```

| Réponse | Signification                                                     |
| ------- | ----------------------------------------------------------------- |
| `200`   | Le document est de nouveau vivant.                                 |
| `404`   | Le document n’a pas d’historique à restaurer.                      |
| `409`   | Le document n’est pas supprimé. Rechargez plutôt que de réessayer. |
| `403`   | Votre rôle n’a pas `update` sur le document.                       |
| `422`   | Historique dégénéréà : une suppression sans changement avant elle.  |

## Explication

### Ce qu’écrit un retour arrière

Le service rejoue l’historique jusqu’à la cible et persiste une nouvelle
mutation `snapshot`. L’instantané enregistre votre id de compte comme
acteur. Les appelants internes enregistrent `system:rollback`. Son
`cause_kind` est `rollback`, et son `cause_parent` nomme la mutation cible,
si bien que la piste d’audit relie l’instantané à la cible exacte.

### Les limites

- **La profondeur du retour arrière égale la fenêtre de rétention.** La
  passe de compactage remplace les lignes plus anciennes par un instantané
  par document. Une cible plus ancienne que la fenêtre répond `404`. Le
  corps nomme la fenêtre effectiveà : les routes document, enfant et
  restauration nomment la fenêtre pour ce doctypeà ; la route globale nomme
  la fenêtre de baseà ; une fenêtre de `0` signifie l’historique complet.
- **Un retour arrière vers une suppression restaure le document.** La cible
  se résout au changement immédiatement avant la suppression. L’instantané
  efface le marqueur de suppression, et le document est de nouveau vivant.
- **Une suppression sans changement avant elle n’a rien à restaurer.** La
  requête répond `422`.

### Les enfants reviennent avec le document

Une restauration ramène aussi les enfants de composition que la suppression
annulée avait retirés. La pré-vérification contrôle chaque enfant avant
toute écritureà ; un seul refus avorte toute la restauration. Chaque enfant
reçoit sa propre mutation d’instantané. La réponse les liste dans
`cascade_restored` :

```json
"cascade_restored": [
  {
    "domain": "production",
    "doc_type": "Project.Task",
    "doc_id": "01BQ5M2X9K4T6VBNR8D3Q5M2X7",
    "mut_id": "01D3Q5M2X7BQ5M2XA9K4T6VBNR8"
  }
]
```

### Qui peut revenir en arrière

L’appelant demande `update` sur le document. Deux barrières de transition
peuvent encore refuser avec `403` :

- La barrière d’autorité des rôles refuse un retour arrière qui
  ressusciterait un état d’identité plus fort, par exemple une ancienne
  affectation du rôle admin.
- La barrière de visibilité des champs refuse un retour arrière qui
  rembobinerait une valeur dans un champ que votre rôle ne peut pas voir.

:::caution[Le document prend tout le contenu de la cible]
Le document prend tout le contenu de l’état cible. Les changements faits
après la cible quittent le document. Ils restent dans l’historique.
Choisissez une cible plus tardive et revenez en arrière une seconde fois
pour y retourner.
:::

## Dépannage

### Le retour arrière répond `404` et nomme une fenêtre

La cible est plus ancienne que la fenêtre de rétention. Choisissez une
cible plus récente, ou élargissez la fenêtre avant la prochaine passe de
compactage — voir [La rétention](/fr/govern/retention/).

### Le retour arrière répond `422` pour un id bien formé

L’id peut nommer une suppression sans changement avant elle, ou un
changement que la fusion à l’écriture a replié — voir
[La rétention](/fr/govern/retention/).

### Le retour arrière répond `403`

Il vous manque `update` sur le document, ou une barrière de transition a
refusé le résultat. Vérifiez votre rôle actif et les étiquettes des champs
rembobinés.

### La restauration répond `409`

Le document est vivant. Rechargez-le plutôt que de réessayer.

## Voir aussi

- [Historique et annulation](/fr/workspace/history-undo/) — la surface
  d’annulation pour l’utilisateur final.
- [Auditer l’activité](/fr/govern/auditing-activity/) — trouvez la mutation
  cible.
- [La rétention](/fr/govern/retention/) — pourquoi la profondeur égale la
  fenêtre.
- [Le journal des mutations](/fr/concepts/mutation-log/) — ce qu’est une
  ligne d’instantané.
- Internes sur GitHubà :
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
