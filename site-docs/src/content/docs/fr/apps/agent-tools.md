---
title: Outils pour agents
description: Utilisez le catalogue partagé de tools documentaires qui sert les clients MCP et l’assistant embarqué.
audience: [developer]
features: [AI-04, AI-06]
sidebar:
  order: 18
verified_at: a77c6171
---

Un seul catalogue de tools documentaires dessert toutes les surfaces d’agent. Le serveur
MCP et l’assistant embarqué montent les mêmes entrées. Quelle que soit la surface qui
appelle, les capacités, le RBAC, les limites et la correspondance des erreurs sont
identiques.

> **Pour les agents :** appelez les tools avec `tools/call` — connectez-vous via
> [MCP : connecter des agents](/fr/apps/mcp-agents/). Séquence : `tools/list` → `whoami` →
> `get_schema` avant toute écriture → `list_documents` avec des filtres `field__op` →
> `create_document` / `update_document` (JSON merge patch ; `null` supprime une clé) →
> `batch` (25 opérations au plus). Une clé de filtre que le doctype ne déclare pas lève
> `InvalidParams` — jamais un résultat vide en silence. Les erreurs portent `data.reason` ;
> limites : 200 lignes, enveloppe de 1 Mio, 25 opérations par batch. Les fichiers passent
> par HTTP : `request_artifact_upload` fabrique une URL signée.

:::note[Uniquement des tools documentaires]
Le catalogue ne couvre pas la conception de schéma : ni création ni modification de
domaine ou de doctype, ni publication. `create_document` écrit dans un doctype déjà
enregistré ; il n’enregistre pas de doctype. La conception de schéma revient à REST et à

l’assistant de construction de domaines.
:::

## Quand l’utiliser

Utilisez cette page quand :

- vous construisez un agent sur la surface MCP, ou vous étendez l’assistant ;
- vous devez savoir quels tools existent, ce qu’ils exigent et ce qu’ils renvoient ;
- un appel de tool échoue, et vous avez besoin du contrat d’erreurs.

## Avant de commencer

- Connectez-vous d’abord — voir [MCP : connecter des agents](/fr/apps/mcp-agents/). Cette
  page parle MCP ; l’assistant monte les mêmes entrées.
- Appelez `whoami` d’abord : il renvoie le rôle, les lignes de permission, les périmètres
  et les étiquettes visibles. Un champ dont l’étiquette est hors de `visible_tags`
  n’apparaît dans aucun résultat.

## Le catalogue

`requires` est la ligne de permission que le rôle doit porter pour que le tool apparaisse
dans `tools/list` :

| Tool | `requires` | Fonction |
| --- | --- | --- |
| `ping` | none | Identité du serveur et rôle monté. |
| `list_domains` | read | Domaines réels ; brouillons exclus. |
| `list_doctypes` | read | Les doctypes d’un domaine. |
| `get_schema` | read | Définition complète du doctype : champs, actions, périmètres, `member_of`, sidecars. |
| `whoami` | none | Identité, permissions, périmètres, étiquettes visibles. |
| `list_documents` | read | Liste filtrée, triée, paginée. |
| `aggregate_documents` | read | `count`, ou `sum`/`avg`/`min`/`max` sur un champ entier, durée ou monétaire. |
| `get_document` | read | Un document par id ; `expand` et `fields` facultatifs. |
| `create_document` | write | Création avec le contenu complet ; `parent_id` crée un enfant. |
| `update_document` | write | JSON merge patch (RFC 7386) ; `null` supprime une clé. |
| `delete_document` | write | Suppression logique — un tombstone. |
| `batch` | write | Opérations atomiques ordonnées en une transaction. |
| `call_action` | action | Action nommée du doctype avec arguments typés. |
| `create_sidecar` | write | Création d’un sidecar sur le segment d’un document hôte. |
| `list_sidecars` | read | Le segment de sidecars d’un hôte, paginé. |
| `list_mutations` | read | Historique d’un document — ou tout le journal, avec des droits de lecture en joker. |
| `resolve_refs` | read | Un lot d’URN résolu en lignes de stub. |
| `get_links` | read | Les liens sortants d’un document. |
| `get_backrefs` | read | Les documents réels qui pointent vers un document. |
| `search_documents` | read | Recherche sur plusieurs doctypes ; 5 correspondances par doctype. |
| `request_artifact_upload` | write | Une URL de téléversement signée, à usage unique, pour un fichier. |
| `get_artifact` | read | Une URL de téléchargement signée, à courte durée de vie. |
| `list_artifact_refs` | read | Les documents réels qui référencent un artefact. |

`read_skill` ne fait pas partie du catalogue. Chaque surface monte son propre chargeur ;
le montage MCP sert de courtes références markdown pour ces tools.

## Étapes

### 1. Lister les tools et lire le schéma

`tools/list` renvoie la liste filtrée par rôle. La visibilité est un confort pour
l’agent, jamais un garde-fou : le contrôle s’exécute à l’appel, exactement comme en REST.
Lisez `get_schema` avant toute écriture. Il porte les champs, les actions, les périmètres,
le lien parent `member_of` et les segments de sidecars de l’hôte.

### 2. Lister et lire des documents

`list_documents` prend `domain` et `doctype`, plus :

| Argument | Fonction |
| --- | --- |
| `filters` | Clés `field__op` — `status__eq`, `salary__gte`, `name__match` |
| `sort` | Noms de champs ; un préfixe `-` trie par ordre décroissant |
| `page`, `items` | pagination |
| `fields` | Ne garde, pour chaque ligne, que les champs nommés |
| `expand` | Résout les champs de référence dans une map `resolved` |
| `scope` | Applique un périmètre de lignes nommé comme filtre au moment de la requête |
| `parent_id` | Liste les enfants d’un parent ; doctypes enfants seulement |

Les clés de filtre sont validées par rapport au doctype. Une clé inconnue, ou un opérateur
que le champ ne gère pas, lève `InvalidParams` — jamais un résultat vide en silence.
`parent_id` passe par le périmètre de lecture du parent — la même barrière que la route
REST imbriquée. Un résultat trop grand définit `meta.truncated: true` et porte
`next_cursor` ; récupérez ensuite cette page. Le `meta` de chaque ligne porte
`display_name`. `aggregate_documents` tourne sous les mêmes filtres et les mêmes limites.

### 3. Écrire des documents

`create_document` prend le contenu complet. Un doctype enfant exige `parent_id` ; un
enfant sans lui est refusé. `update_document` prend un JSON merge patch : les nouvelles
clés sont posées, et une valeur `null` supprime la clé. `delete_document` transforme le
document en tombstone. `batch` exécute dans l’ordre des opérations `create`, `update`,
`delete` et `action` en une transaction ; un échec annule tout le batch et nomme l’index
de l’opération.

### 4. Agir, étendre et inspecter

`call_action` exécute une action nommée avec des arguments typés. `create_sidecar` et
`list_sidecars` opèrent sur un segment d’un document hôte. `list_mutations` renvoie
l’historique d’un document ; sans `doc_id`, il sert tout le journal à un appelant avec des
droits de lecture en joker. `resolve_refs`, `get_links` et `get_backrefs` parcourent le
graphe de références. `search_documents` diffuse un terme de recherche sur tous les
doctypes lisibles.

### 5. Faire passer les fichiers par HTTP

Aucun octet de fichier ne circule dans le canal des tools :

1. Appelez `request_artifact_upload`. Il renvoie une URL de téléversement signée, à usage
   unique.
2. POSTez la partie multipart `file` vers cette URL.
3. Placez l’id d’artefact renvoyé dans un document.
4. Appelez `get_artifact` pour une URL de téléchargement, ou `list_artifact_refs` pour
   voir où un artefact est utilisé.

  Voir [Téléverser et servir des fichiers](/fr/apps/files/) pour le côté HTTP.

## Limites et erreurs

Les limites viennent du bloc `mcp:` : 200 lignes, enveloppe de 1 Mio, 25 opérations par
batch — voir [MCP : connecter des agents](/fr/apps/mcp-agents/). Un résultat trop grand
est coupé, pas rejeté : il définit `meta.truncated` et `next_cursor`. Les échecs sont des
erreurs JSON-RPC :

| Classe d’erreur | Code JSON-RPC | Signification |
| --- | --- | --- |
| `InvalidParams` | `-32602` | Arguments invalides ; les clés d’argument inconnues sont rejetées par un contrôle central |
| `RbacDenied` | `-32603` | Le rôle n’a pas la permission ; l’erreur ne nomme jamais la ligne fautive |
| `NotFound` | `-32602` | Documents inconnus, en tombstone ou invisibles : une même réponse sans divulgation |
| `Capped` | `-32603` | Le résultat dépasse une limite |
| `ToolError` | `-32603` | Dernier recours |

Chaque échec porte un `data.reason` lisible par la machine :

| `data.reason` | Classe | Clés supplémentaires |
| --- | --- | --- |
| `invalid_params` | `InvalidParams` | `argument` |
| `unknown_argument` | `InvalidParams` | `argument`, `tool` |
| `unknown_field` | `InvalidParams` | `field` |
| `unsupported_operator` | `InvalidParams` | `field`, `operator` |
| `unknown_tool` | `NotFound` | `tool` |
| `not_found` | `NotFound` | `deleted: true` sur un tombstone |
| `rbac_denied` | `RbacDenied` | — |
| `capped` | `Capped` | `cap` |

Un échec de validation à l’écriture porte les erreurs par champ dans `data.details`.

## Exemple

La requête :

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "list_documents",
    "arguments": {
      "domain": "crm",
      "doctype": "Contact",
      "filters": { "status__eq": "active" },
      "sort": ["-created_at"],
      "page": 1
    }
  }
}
```

Le payload revient dans `result.structuredContent` ; le même payload revient aussi sous
forme de chaîne JSON dans `result.content[0].text` :

```json
{
  "data": [
    {
      "data": { "name": "Ada Lovelace", "status": "active" },
      "meta": {
        "id": "01JE2W4G7Q2M8X3K5P9R2T4V6W",
        "domain": "crm",
        "doc_type": "Contact",
        "mid": "01JE2W4G7Q2M8X3K5P9R2T4V6X",
        "version": 1,
        "created_at": "2026-11-13T09:12:44Z",
        "updated_at": "2026-11-13T09:12:44Z",
        "display_name": "Ada Lovelace"
      }
    }
  ],
  "meta": { "total": 1, "page": 1, "items": 1, "truncated": false, "next_cursor": null }
}
```

`truncated: false` avec `next_cursor: null` indique une dernière page. Une page coupée par
la limite de lignes ou d’octets définit `truncated: true` et place `next_cursor` sur le
numéro de la page suivante.

Une création :

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "create_document",
    "arguments": {
      "domain": "crm",
      "doctype": "Contact",
      "content": { "name": "Grace Hopper", "email": "grace@example.com", "status": "active" }
    }
  }
}
```

Le résultat porte le contenu créé et la même structure de meta, avec un `id` et un `mid`
neufs.

## Dépannage

**La réponse est `unknown_argument`.**

Une clé qu’aucun gestionnaire ne lit — vérifiez l’`inputSchema` du tool dans
`tools/list`.

**Un tool listé répond `rbac_denied`.**

Apparaître dans la liste n’est que de la visibilité ; le rôle contrôle toujours l’appel.
Vérifiez les lignes de permission avec `whoami`.

**Les résultats s’arrêtent sur `truncated: true`.**

Récupérez la page que `next_cursor` nomme. La coupure est une limite, pas un échec.

**`NotFound` pour un document visible ailleurs.**

Périmètre de lignes, ou lecture sans divulgation. Vérifiez `whoami` ; les documents en
tombstone et invisibles donnent la même réponse.

## Voir aussi

- [MCP : connecter des agents](/fr/apps/mcp-agents/) — la surface qui sert ce catalogue.
- [Utiliser l’API REST](/fr/apps/rest-api/) — les mêmes filtres et les mêmes erreurs sur HTTP.
- [Recherche](/fr/apps/search/) — le corpus sur lequel `search_documents` diffuse.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) — le modèle de droits.
- Internes sur GitHub : [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md).
