---
title: Ce que les agents peuvent faire
description: Catalogue partagé des tools documentaires servi aux clients MCP et à l’assistant — familles, droits, limites et erreurs.
type: how-to
audience: [developer]
features: [AI-04, AI-06]
verified_at: eee55a2
sidebar:
  order: 2
---

Un seul catalogue de tools documentaires dessert toutes les surfaces
d’agent. Le serveur MCP et l’assistant embarqué montent les mêmes entrées.
Quelle que soit la surface qui appelle, les capacités, le RBAC, les limites
et la correspondance des erreurs sont identiques. La liste générée complète
— chaque tool avec ses paramètres — se trouve dans
[la référence des tools d’agent](/fr/reference/agent-tools/) ; cette page
explique le comportement du catalogue.

> **Pour les agents :** appelez les tools avec `tools/call` — connectez-vous via
> [Connecter des agents par MCP](/fr/build/apps/agents/mcp/). Séquence : `tools/list` → `whoami` →
> `get_schema` avant toute écriture → `list_documents` avec des filtres `field__op` →
> `create_document` / `update_document` (JSON merge patch ; `null` supprime une clé) →
> `batch` (25 opérations au plus). Une clé de filtre que le doctype ne déclare pas lève
> `-32602` — jamais un résultat vide en silence. Les erreurs portent
> `data.reason` ; limites : 200 lignes, enveloppe de 1 Mio, 25 opérations par batch.
> Les fichiers passent par HTTP : `request_artifact_upload` fabrique une URL signée.

:::note[Uniquement des tools documentaires]
Le catalogue ne porte aucune conception de schéma : ni création ni
modification de domaine ou de doctype, ni publication. `create_document`
écrit dans un doctype déjà enregistré ; il n’enregistre pas de doctype. La
conception de schéma revient à REST et à l’assistant du builder.
:::

## Quand l’utiliser

Utilisez cette page quand :

- Vous construisez un agent sur la surface MCP, ou vous étendez
  l’assistant.
- Vous devez savoir quels tools existent, ce qu’ils exigent et ce qu’ils
  renvoient.
- Un appel de tool échoue, et vous avez besoin du contrat d’erreurs.

## Avant de commencer

- Connectez-vous d’abord — voir
  [Connecter des agents par MCP](/fr/build/apps/agents/mcp/). Cette page parle
  MCP ; l’assistant monte les mêmes entrées.
- Appelez `whoami` d’abord : il renvoie le rôle, les lignes de permission,
  les périmètres et les étiquettes visibles. Les champs dont les étiquettes
  sortent de `visible_tags` sont absents de tous les résultats.

## Le catalogue par famille

Le registre contient 23 tools ; le montage MCP ajoute `read_skill`, soit 24
dans `tools/list`. Ils se répartissent en six familles :

| Famille | Tools | Classe de droits |
| --- | --- | --- |
| Surface | `ping`, `whoami` | none |
| Découverte | `list_domains`, `list_doctypes`, `get_schema`, `read_skill` | read |
| Lecture | `list_documents`, `aggregate_documents`, `get_document`, `resolve_refs`, `get_links`, `get_backrefs`, `search_documents`, `list_mutations`, `list_sidecars`, `list_artifact_refs` | read |
| Écriture | `create_document`, `update_document`, `delete_document`, `batch`, `create_sidecar` | write |
| Actions | `call_action` | action |
| Fichiers | `request_artifact_upload`, `get_artifact` | write / read |

`read_skill` n’est pas une entrée du catalogue. Chaque surface monte son
propre chargeur ; le montage MCP sert de courtes références markdown pour
ces tools.

La ligne `requires` d’un tool conditionne sa présence dans `tools/list` :
`read` pour un rôle qui lit la cible, `write` pour un rôle qui écrit,
`action` pour un rôle qui peut exécuter les actions non CRUD du doctype. La
visibilité est un confort pour l’agent, jamais une limite : le contrôle
s’exécute à l’appel, exactement comme en REST.

## Étapes

### 1. Lister les tools et lire le schéma

`tools/list` renvoie la liste filtrée par rôle. Lisez `get_schema` avant
toute écriture. Il porte les champs, les actions, les périmètres, le lien
parent `member_of` et les segments de sidecars de l’hôte. Sur l’instance
Brightwater, `get_schema` sur `clients.Company` nomme les champs filtrables
avant tout appel.

### 2. Lister et lire des documents

`list_documents` prend `domain` et `doctype`, plus :

| Argument | Rôle |
| --- | --- |
| `filters` | Clés `field__op` — `status__eq`, `name__match`, `city__starts_with` |
| `sort` | Noms de champs ; un préfixe `-` trie par ordre décroissant |
| `page`, `items` | pagination |
| `fields` | Projette le contenu de chaque ligne sur les champs nommés |
| `expand` | Résout les champs de référence dans une map `resolved` |
| `scope` | Applique un périmètre de lignes nommé comme filtre au moment de la requête |
| `parent_id` | Liste les enfants d’un parent ; doctypes enfants seulement |

Les clés de filtre sont validées par rapport au doctype. Une clé inconnue,
ou un opérateur que le champ ne gère pas, lève une erreur — jamais un
résultat vide en silence. Depuis une session réelle sur l’instance
Brightwater :

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "error": {
    "code": -32602,
    "message": "Filter operator 'bogus' is not supported for field 'name' on clients.Company (supported: eq, in, match, ne, starts_with)",
    "data": { "reason": "unsupported_operator", "field": "name", "operator": "bogus" }
  }
}
```

`parent_id` passe par le périmètre de lecture du parent, la même barrière
que la route REST imbriquée. Un résultat trop grand définit
`meta.truncated: true` et porte `next_cursor` ; récupérez ensuite cette
page. Le `meta` de chaque ligne porte `display_name`. `aggregate_documents`
tourne sous les mêmes filtres et les mêmes limites.

### 3. Écrire des documents

`create_document` prend le contenu complet. Un doctype enfant exige
`parent_id` ; un enfant sans lui est refusé. `update_document` prend un
JSON merge patch : les nouvelles clés sont posées, et une valeur `null`
supprime la clé. `delete_document` transforme le document en tombstone.
`batch` exécute dans l’ordre des opérations `create`, `update`, `delete` et
`action` en une transaction ; un échec annule le batch et nomme l’index de
l’opération.

### 4. Agir, étendre et inspecter

`call_action` exécute une action nommée avec des arguments typés — sur
Brightwater, l’action `confirm` de `rentals.Booking`. `create_sidecar` et
`list_sidecars` opèrent sur un segment d’un document hôte. `list_mutations`
renvoie l’historique d’un document ; sans `doc_id`, il sert tout le journal
à un lecteur en joker. `resolve_refs`, `get_links` et `get_backrefs`
parcourent le graphe de références. `search_documents` diffuse un terme de
recherche sur tous les doctypes lisibles.

### 5. Faire passer les fichiers par HTTP

Aucun octet de fichier ne circule dans le canal des tools :

1. Appelez `request_artifact_upload`. Il renvoie une URL de téléversement
   signée, à usage unique.
2. POSTez la partie multipart `file` vers cette URL.
3. Placez l’id d’artefact renvoyé dans un document.
4. Appelez `get_artifact` pour une URL de téléchargement, ou
   `list_artifact_refs` pour voir où un artefact est utilisé.

  Voir [Téléverser et servir des fichiers](/fr/build/apps/data/files/) pour le côté HTTP.

## Limites et erreurs

Les limites viennent du bloc `mcp:` : 200 lignes, enveloppe de 1 Mio, 25
opérations par batch — voir
[Connecter des agents par MCP](/fr/build/apps/agents/mcp/). Un résultat trop
grand est coupé, pas rejeté : il définit `meta.truncated` et `next_cursor`.
Les échecs sont des erreurs JSON-RPC :

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

Trois raisons, en exemples réels :

```json
{ "code": -32602, "message": "Unknown tool: no_such_tool",
  "data": { "reason": "unknown_tool", "tool": "no_such_tool" } }
```

```json
{ "code": -32602, "message": "Unknown argument 'aggregate' for tool 'list_documents' (accepted: doctype, domain, expand, fields, filters, items, page, parent_id, scope, sort)",
  "data": { "reason": "unknown_argument", "argument": "aggregate", "tool": "list_documents" } }
```

```json
{ "code": -32603, "message": "Argument 'ops' must hold between 1 and 25 entries (got 26)",
  "data": { "reason": "capped", "cap": 25 } }
```

Un échec de validation à l’écriture porte les erreurs par champ dans
`data.details`.

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
      "domain": "clients",
      "doctype": "Company",
      "filters": { "city__eq": "Lyon" },
      "sort": ["-created_at"],
      "page": 1
    }
  }
}
```

Le payload voyage dans `result.structuredContent` ; le même payload voyage
aussi sous forme de chaîne JSON dans `result.content[0].text` :

```json
{
  "data": [
    {
      "data": { "name": "Maison Lumière", "city": "Lyon" },
      "meta": {
        "id": "06H1FM1B3MXBPS0JYVM3BDD154",
        "domain": "clients",
        "doc_type": "Company",
        "mid": "06H1FM1B3MWR784V64VP6QFM94",
        "version": 1,
        "created_at": "2026-11-26T12:24:08Z",
        "updated_at": "2026-11-26T12:24:08Z",
        "display_name": "Maison Lumière"
      }
    }
  ],
  "meta": { "total": 1, "page": 1, "items": 1, "truncated": false, "next_cursor": null }
}
```

`truncated: false` avec `next_cursor: null` indique une dernière page. Une
page coupée par la limite de lignes ou d’octets définit `truncated: true`
et place `next_cursor` sur le numéro de la page suivante.

Une lecture de tombstone nomme la suppression sans rien révéler d’autre :

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32602,
    "message": "Document clients.Company#06H1FRV45MM80SVH32K5JCA6BH not found (deleted)",
    "data": { "reason": "not_found", "deleted": true }
  }
}
```

La liste générée complète des tools, des paramètres et des classes d’accès
se trouve dans [la référence des tools d’agent](/fr/reference/agent-tools/).

## Dépannage

**La réponse est `unknown_argument`.**

Une clé qu’aucun gestionnaire ne lit — vérifiez l’`inputSchema` du tool
dans `tools/list`.

**Un tool listé répond `rbac_denied`.**

Apparaître dans la liste n’est que de la visibilité ; le rôle contrôle
toujours l’appel. Vérifiez les lignes de permission avec `whoami`.

**Les résultats s’arrêtent sur `truncated: true`.**

Récupérez la page que `next_cursor` nomme. La coupure est une limite, pas
un échec.

**`NotFound` pour un document visible ailleurs.**

Périmètre de lignes, ou lecture sans divulgation. Vérifiez `whoami` ; les
documents en tombstone et invisibles donnent la même réponse.

## Voir aussi

- [Connecter des agents par MCP](/fr/build/apps/agents/mcp/) — la surface qui sert ce catalogue.
- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — les mêmes filtres et les mêmes erreurs sur HTTP.
- [Recherche](/fr/build/apps/data/search/) — le corpus sur lequel `search_documents` diffuse.
- [Outils d’agent](/fr/reference/agent-tools/) — la liste générée complète.
- [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) — le modèle de droits.
