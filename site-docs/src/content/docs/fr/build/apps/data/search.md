---
title: Rechercher depuis une app
description: Trouvez des documents de plusieurs doctypes avec un seul appel de recherche classé, limité aux libellés.
type: how-to
audience: [developer]
features: [DOC-06]
verified_at: eee55a2
sidebar:
  order: 2
---

La recherche répond à un terme par une réponse classée unique. Elle lit
chaque doctype interrogeable que l’identifiant a le droit de lire, dans un
seul domaine ou sur toute l’application. Elle ne renvoie que des libellés,
jamais le contenu des documents. C’est cet endpoint qu’appelle la palette de
commandes de Facet ; votre app peut l’appeler aussi.

> **Pour les agents :** `GET /Api/<domain>/search?q=<term>` (un domaine) ou
> `GET /Api/search?q=<term>` (toute l’app). Un seul paramètre `q` ; un terme de
> moins de 2 caractères répond `200` avec un résultat vide, jamais une erreur.
> Les correspondances arrivent groupées par doctype, dans l’ordre du
> classement ; chacune porte `id`, `display_name`, `rank`, `root_doctype`,
> `root_id`, `root_display_name`, `child_label` — des libellés seulement, pas
> de contenu. Récupérez le document par `root_id` (ou `id`) pour lire le
> contenu. Forme QUERY : `-X QUERY` avec `{"q": "<term>"}` dans un corps JSON ;
> tout paramètre de query string répond `422`.

## Quand l’utiliser

Utilisez la recherche quand :

- Vous construisez un sélecteur sur le modèle de la palette de commandes, ou
  une boîte de recherche globale.
- Vous voulez des documents de plusieurs doctypes à partir d’un seul terme.
- Vous devez trouver des documents sans connaître d’avance leur doctype.

Pour filtrer un doctype connu, passez par les filtres de liste — voir
[Utiliser l’API REST](/fr/build/apps/data/rest-api/).

## Avant de commencer

- Un identifiant avec une attribution de lecture sur les doctypes que vous
  voulez trouver. Un doctype sans attribution de lecture ne contribue rien à
  la réponse.
- Un doctype entre dans la recherche seulement quand sa définition déclare un
  modèle `search` non vide. Les doctypes internes restent dehors en n’en
  déclarant pas.
- Sur l’API de liste brute, un doctype sans modèle reste trouvable par son
  libellé via le simple filtre `search` — voir
  [Utiliser l’API REST](/fr/build/apps/data/rest-api/).

Les exemples ont été exécutés sur une instance de dev à l’adresse
`https://facet.localhost:3443` avec les données Brightwater Rentals chargées.
Connectez-vous d’abord et émettez une clé API — voir
[Utiliser l’API REST](/fr/build/apps/data/rest-api/) pour les deux appels —
et gardez-la dans une variable :

## Étapes

### 1. Choisissez le périmètre

Deux routes existent, chacune avec une forme GET et une forme QUERY :

| Route | Périmètre |
| --- | --- |
| `GET /Api/clients/search` | Un domaine. |
| `GET /Api/search` | Toute l’application. |

La route sur toute l’app exécute une requête par groupe de stockage et
fusionne les résultats par rang. Un domaine inconnu répond `404`. Un domaine
de brouillon répond `200` avec un résultat vide et reste exclu de la route
sur toute l’app :

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/clients/search?q=Lumière'

curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/search?q=Lumière'
```

### 2. Envoyez le terme

Un seul paramètre existe : `q`. Un terme de moins de 2 caractères après
suppression des espaces, ou un terme absent, répond `200` avec un résultat
vide — jamais une erreur. Appliquez la même règle côté client avant d’appeler.

La forme `QUERY` porte `q` dans un corps JSON uniquement :

```sh
curl -sk -X QUERY 'https://facet.localhost:3443/Api/clients/search' \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "q": "Lumière" }'
```

Tout paramètre de query string sur une requête `QUERY` répond `422`. Un corps
avec un `Content-Type` non JSON répond `415`.

### 3. Lisez la réponse

La recherche sur toute l’app pour `Lumière` sur les données Brightwater
répond :

```json
{
  "data": [
    {
      "domain": "clients",
      "doctype": "Company",
      "hits": [
        {
          "id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "display_name": "Maison Lumière",
          "rank": 0.4444444477558136,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": null
        }
      ]
    },
    {
      "domain": "clients",
      "doctype": "Contact",
      "hits": [
        {
          "id": "06H1FM1C1MN3MMVH7KH5H8THSA",
          "display_name": "Marc Dubois",
          "rank": 0.24242424964904785,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": "Marc Dubois"
        },
        {
          "id": "06H1FM1BZW99TG47BEJ2H1D73T",
          "display_name": "Claire Fontaine",
          "rank": 0.24242424964904785,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": "Claire Fontaine"
        }
      ]
    },
    {
      "domain": "rentals",
      "doctype": "Booking",
      "hits": [
        {
          "id": "BK-2026-0001",
          "display_name": "Maison Lumière",
          "rank": 0.190476194024086,
          "root_doctype": "Booking",
          "root_id": "BK-2026-0001",
          "root_display_name": "Maison Lumière",
          "child_label": null
        }
      ]
    }
  ],
  "meta": { "q": "Maison", "count": 5, "domain": null }
}
```

| Champ | Signification |
| --- | --- |
| `id`, `display_name` | La ligne trouvée : son id et son libellé. |
| `rank` | Score de correspondance ; le serveur trie les correspondances selon ce score, par ordre décroissant. |
| `root_doctype`, `root_id`, `root_display_name` | Le document racine auquel la correspondance se rattache. |
| `child_label` | Le libellé propre de l’enfant trouvé sur une correspondance enfant ; `null` sur une correspondance racine. |
| `meta.q` | Le terme tel que reçu. |
| `meta.count` | Le nombre de correspondances dans la réponse. |
| `meta.scope` | `domain` ou `app`. |

Chaque correspondance se rattache à un document racine. Une correspondance
sur un doctype racine se rattache à elle-même. Une correspondance sur un
enfant en composition se rattache à la racine de l’agrégat, pour que l’app
puisse toujours ouvrir la page derrière la correspondance. Les deux
correspondances Contact ci-dessus se rattachent toutes deux à Maison
Lumière — regroupez-les côté client, avec l’enfant le mieux classé en
sous-titre.

Seuls les doctypes avec une attribution de lecture contribuent. Une
correspondance enfant disparaît quand sa racine est illisible, supprimée, ou
quand la chaîne casse. Le client ne reçoit rien que l’identifiant ne puisse
ouvrir. Tom ne voit que ses cinq sociétés ; une recherche qui trouverait une
autre société répond sans elle.

Les plafonds sont des constantes du serveur, pas des paramètres de requête :

| Constante | Valeur | Rôle |
| --- | --- | --- |
| `MIN_TERM_LENGTH` | 2 | Les termes plus courts répondent vide. |
| `PER_DOCTYPE_CAP` | 5 | Correspondances par groupe de doctype. |
| `OVERALL_CAP` | 25 | Correspondances dans la réponse. |
| `MAX_COMPOSITION_DEPTH` | 8 | Limite de la remontée de l’enfant vers la racine. |

### 4. Récupérez les documents

Les correspondances portent des libellés, jamais le contenu. Récupérez le
contenu avec une lecture de document sur `root_id`, ou sur `id` quand la
correspondance est la racine :

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154'
```

Voir [Utiliser l’API REST](/fr/build/apps/data/rest-api/) pour l’enveloppe de
document.

## Exemple

Un seul appel produit les libellés d’une boîte de recherche :

```ts
const response = await fetch('https://facet.localhost:3443/Api/search?q=Lumière', {
	headers: { Authorization: `Bearer ${process.env.FACET_API_KEY}` }
});
if (!response.ok) throw new Error(`search failed: ${response.status}`);

const { data } = await response.json();
for (const group of data) {
	for (const hit of group.hits) {
		console.log(hit.root_display_name, hit.rank);
	}
}
```

## Dépannage

**Résultats vides pour un terme pourtant présent.**

Quatre causes répondent vide, jamais une erreur : le doctype ne déclare pas
de modèle `search` ; le terme fait moins de 2 caractères après suppression
des espaces ; les lignes sont supprimées ; ou l’identifiant ne porte aucune
attribution de lecture sur le doctype.

**La recherche sur toute l’app manque un domaine entier.**

Un domaine de brouillon reste exclu de la route sur toute l’app. Un appel
limité à un domaine de brouillon répond aussi vide.

**Un domaine inconnu répond `404`.**

La route vérifie le domaine avant d’interroger. Le `404` ne divulgue rien.

**Les correspondances ne portent aucun contenu.**

C’est voulu : des libellés seulement. Récupérez chaque document par
`root_id` ou `id` (étape 4).

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — les filtres de liste pour un
  seul doctype.
- [Outils pour agents](/fr/build/apps/agents/agent-tools/) — l’outil `search_documents`
  pour les agents.
- Internes sur GitHub :
  [search.md](https://github.com/wearefacet/facet/blob/main/doc/backend/search.md).
