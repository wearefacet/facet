---
title: Recherche
description: Retrouvez des documents de plusieurs doctypes avec l’endpoint de recherche.
audience: [developer]
features: [DOC-06]
sidebar:
  order: 11
verified_at: a77c6171
---

La recherche répond à un terme par une réponse classée. Elle parcourt tous les
doctypes interrogeables que l’identifiant a le droit de lire, dans un domaine
ou sur toute l’app. Elle ne renvoie que des libellés, jamais le contenu des
documents. C’est cet endpoint qu’appelle la palette de commandes de l’app.

> **Pour les agentsà :** `GET /Api/<domain>/search?q=<term>` (un domaine) ou
> `GET /Api/search?q=<term>` (toute l’app). Un seul paramètre `q` ; un terme de
> moins de 2 caractères répond `200` avec un résultat vide, jamais une erreur.
> Les correspondances arrivent groupées par doctype, dans l’ordre du
> classementà ; chacune porte `id`, `display_name`, `rank`, `root_doctype`,
> `root_id`, `root_display_name`, `child_label` — des libellés seulement, pas
> de contenu. Récupérez le document par `root_id` (ou `id`) pour lire le
> contenu. Forme QUERYà: `-X QUERY` avec `{"q": "<term>"}` dans un corps JSONà;
> tout paramètre de query string répond `422`.

## Quand l’utiliser

Utilisez la recherche quandà :

- Vous construisez un sélecteur sur le modèle de la palette de commandes, ou
  une boîte de recherche globale.
- Vous voulez des documents de plusieurs doctypes à partir d’un seul terme.
- Vous devez trouver des documents sans connaître d’avance leur doctype.

Pour filtrer un doctype connu, passez par les filtres de liste — voir
[Utiliser l’API REST](/fr/apps/rest-api/).

## Avant de commencer

- Un identifiant avec une attribution de lecture sur les doctypes que vous
  voulez trouver. Un doctype sans attribution de lecture ne contribue rien à

  la réponse.
- Un doctype entre dans la recherche seulement quand sa définition déclare un
  modèle `search` non vide. Les doctypes internes restent dehors en n’en
  déclarant pas.
- Sur l’API de liste brute, un doctype sans modèle reste trouvable par son
  libellé via le simple filtre `search` — voir
  [Utiliser l’API REST](/fr/apps/rest-api/).

  Les exemples utilisent `https://facet.example.com` et le domaine `crm`.
  Remplacez les deux par vos valeurs.

## Étapes

### 1. Choisissez le périmètre

Deux routes existent, chacune avec une forme GET et une forme QUERYà:

| Route                 | Périmètre    |
| --------------------- | ------------ |
| `GET /Api/crm/search` | Un domaine.  |
| `GET /Api/search`     | Toute l’app. |

La route sur toute l’app exécute une requête par groupe de stockage et
fusionne les résultats par rang. Un domaine inconnu répond `404`. Un domaine
de brouillon répond `200` avec un résultat vide et reste exclu de la route sur
toute l’appà :

```sh
curl "https://facet.example.com/Api/crm/search?q=acme" \
  -H "Authorization: Bearer $FACET_API_KEY"

curl "https://facet.example.com/Api/search?q=acme" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

### 2. Envoyez le terme

Un seul paramètre existeà : `q`. Un terme de moins de 2 caractères après
suppression des espaces, ou un terme absent, répond `200` avec un résultat
vide — jamais une erreur. Appliquez la même règle côté client avant d’appeler.

La forme `QUERY` porte `q` dans un corps JSON uniquementà :

```sh
curl -X QUERY "https://facet.example.com/Api/crm/search" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "q": "acme" }'
```

Tout paramètre de query string sur une requête `QUERY` répond `422`. Un corps
avec un `Content-Type` non JSON répond `415`.

### 3. Lisez la réponse

La réponse est l’enveloppe standard. `data` contient des groupes par doctype,
dans l’ordre du classement. Chaque groupe porte `domain` et `doctype` ; les
correspondances héritent de ces valeursà :

```json
{
  "data": [
    {
      "domain": "crm",
      "doctype": "Company",
      "hits": [
        {
          "id": "01JD8W2G7Q5M2X9K4T6VBNR8D",
          "display_name": "Acme",
          "rank": 0.83,
          "root_doctype": "Company",
          "root_id": "01JD8W2G7Q5M2X9K4T6VBNR8D",
          "root_display_name": "Acme",
          "child_label": null
        }
      ]
    }
  ],
  "meta": { "q": "acme", "count": 1, "scope": "domain" }
}
```

| Champ                                          | Signification |
| ---------------------------------------------- | ------------- |
| `id`, `display_name`                           | La ligne trouvéeà : son id et son libellé. |
| `rank`                                         | Score de correspondanceà ; le serveur trie les correspondances selon ce score, par ordre décroissant. |
| `root_doctype`, `root_id`, `root_display_name` | Le document racine auquel la correspondance se rattache. |
| `child_label`                                  | Le libellé propre de l’enfant trouvé sur une correspondance enfantà ; `null` sur une correspondance racine. |
| `meta.q`                                       | Le terme tel que reçu. |
| `meta.count`                                   | Le nombre de correspondances dans la réponse. |
| `meta.scope`                                   | `domain` ou `app`. |

Chaque correspondance se rattache à un document racine. Une correspondance sur
un doctype racine se rattache à elle-même. Une correspondance sur un enfant en
composition se rattache à la racine de l’agrégat, pour que l’app puisse
toujours ouvrir la page derrière la correspondance. Regroupez une entrée par
racine côté client, avec l’enfant le mieux classé en sous-titre.

Seuls les doctypes avec une attribution de lecture contribuent. Une
correspondance enfant disparaît quand sa racine est illisible, supprimée, ou
quand la chaîne casse. Le client ne reçoit rien que l’identifiant ne puisse
ouvrir.

Les plafonds sont des constantes du serveur, pas des paramètres de requêteà :

| Constante               | Valeur | Rôle                                              |
| ----------------------- | ------ | ------------------------------------------------- |
| `MIN_TERM_LENGTH`       | 2      | Les termes plus courts répondent vide.            |
| `PER_DOCTYPE_CAP`       | 5      | Correspondances par groupe de doctype.            |
| `OVERALL_CAP`           | 25     | Correspondances dans la réponse.                  |
| `MAX_COMPOSITION_DEPTH` | 8      | Limite de la remontée de l’enfant vers la racine. |

### 4. Récupérez les documents

Les correspondances portent des libellés, jamais le contenu. Récupérez le
contenu avec une lecture de document sur `root_id`, ou sur `id` quand la
correspondance est la racineà :

```sh
curl "https://facet.example.com/Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

Voir [Utiliser l’API REST](/fr/apps/rest-api/) pour l’enveloppe de document.

## Exemple

Un seul appel produit les libellés d’une boîte de rechercheà :

```ts
const response = await fetch("https://facet.example.com/Api/search?q=acme", {
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

Quatre causes répondent vide, jamais une erreurà : le doctype ne déclare pas de
modèle `search` ; le terme fait moins de 2 caractères après suppression des
espacesà ; les lignes sont suppriméesà ; ou l’identifiant ne porte aucune
attribution de lecture sur le doctype.

**La recherche sur toute l’app manque un domaine entier.**

Un domaine de brouillon reste exclu de la route sur toute l’app. Un appel
limité à un domaine de brouillon répond aussi vide.

**Un domaine inconnu répond `404`.**

La route vérifie le domaine avant d’interroger. Le `404` ne divulgue rien.

**Les correspondances ne portent aucun contenu.**

C’est vouluà : des libellés seulement. Récupérez chaque document par `root_id`
ou `id` (étape 4).

## Voir aussi

- [Utiliser l’API REST](/fr/apps/rest-api/) — les filtres de liste pour un
  seul doctype.
- [Outils pour agents](/fr/apps/agent-tools/) — l’outil `search_documents`
  pour les agents.
- Internes sur GitHubà :
  [search.md](https://github.com/wearefacet/facet/blob/main/doc/backend/search.md).
