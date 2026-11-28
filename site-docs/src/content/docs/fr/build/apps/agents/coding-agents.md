---
title: Bâtir des apps avec un agent de code
description: Pointez un agent de code vers les pages jumelles .md et l’index llms.txt pour bâtir une app Facet.
type: how-to
audience: [developer]
features: [AI-06]
verified_at: eee55a2
sidebar:
  order: 0
---

Un agent de code peut construire une app Facet à partir de ce site. Chaque
page est livrée sous une forme que les agents consomment, et la documentation
suit des règles qui rendent fiable ce que l’agent produit. Vous pointez
l’agent vers les bonnes pages ; les pages font le reste.

> **Pour les agents :** récupérez d’abord `https://docs.facet.example/llms.txt` —
> il indexe les deux jeux de textes. Un seul sujet : récupérez le jumeau de la page
> à `https://docs.facet.example/<path>.md` — par exemple
> `/build/apps/data/rest-api.md` — markdown octet pour octet, front-matter conservé.
> Plusieurs sections : `/llms-small.txt` (compact) ou `/llms-full.txt` (toutes les
> pages anglaises dans un seul fichier). Les blocs de code de ce site sont
> complets et exécutables — copiez-les ; n’inventez aucun appel.

## Quand l’utiliser

Consultez cette page quand :

- Vous construisez une app Facet avec un agent de code.
- L’agent invente des endpoints ou des paramètres.
- Vous devez limiter la taille du contexte de l’agent.

Pour la modélisation de domaine avec un agent — le dossier de fichiers de
domaine, le watcher et la boucle de vérification —, voir
[Construire des domaines avec un agent de code](/fr/build/model/in-files/with-a-coding-agent/).
Cette page couvre la moitié app : code client, identifiants et appels HTTP.

## Avant de commencer

La génération du site produit chaque page deux fois : la version rendue, et le
markdown brut. Le jeu lisible par une machine :

| Adresse | Contenu |
| --- | --- |
| `/llms.txt` | L’index des deux autres fichiers |
| `/llms-small.txt` | La documentation abrégée — la plupart des pages, moins de détail |
| `/llms-full.txt` | Le texte complet de chaque page anglaise dans un seul fichier |
| `/<path>.md` | Une page en markdown brut — par exemple `/build/apps/data/rest-api.md` |

Le jumeau `.md` est identique octet pour octet : le front-matter (`audience`,
`features`, `verified_at`) reste en place, et un diagramme reste un commentaire
HTML qui porte sa source D2, à côté de l’image rendue. Le bouton
**Copy as markdown** de chaque page récupère le même jumeau. Les exemples
ci-dessous utilisent `https://docs.facet.example`, le placeholder de la
configuration du dépôt ; utilisez l’adresse de la documentation de votre
déploiement.

## Étapes

### 1. Pointer l’agent vers l’index

Récupérez `/llms.txt` d’abord. C’est une seule petite requête, et elle liste
les deux jeux de textes.

### 2. Choisir le jeu de textes

Donnez `/llms-small.txt` à l’agent pour un balayage à faible coût. Donnez-lui
`/llms-full.txt` quand la tâche couvre plusieurs sections.

### 3. Récupérer le jumeau de la page pour un seul sujet

Pour une tâche unique, récupérez le jumeau de la page qui l’enseigne, et
placez son texte dans le contexte de l’agent. La section Exemple porte les
commandes.

### 4. Demander la modification

Demandez à l’agent de copier les blocs de code complets que les pages
portent, au lieu d’inventer des appels. Quand un appel échoue, renvoyez
l’agent vers le jumeau de la page.

## Explication

### Pourquoi ce site convient aux agents

La documentation suit des règles d’écriture qui rendent fiable ce que
l’agent produit :

- Chaque bloc de code est complet et exécutable. Aucune élision `...` :
  l’agent peut coller un bloc tel quel.
- Chaque page de `/build/apps/` ouvre avec un encadré **Pour les agents** :
  endpoints, clés et séquence d’appels minimale en texte brut.
- Les tableaux portent les données de référence : filtres, erreurs, limites.
- Chaque page enseigne une tâche. Une récupération ciblée vaut mieux qu’une
  large.

### Conseils de prompt

- Donnez les URL de base — site de documentation et instance Facet — plus le
  slug de l’app et le canal d’authentification, avant la tâche.
- Quand un appel échoue, demandez à l’agent de relire le jumeau de la page.
  Ne le laissez pas deviner les paramètres.
- Quand le contexte est serré, récupérez la page du doctype ou de la route,
  pas le jeu de textes complet.

### Où se trouve chaque moitié

Un build par agent a deux moitiés, et la documentation les sépare de la même
façon :

| Moitié | Ce que l’agent modifie | Ce qu’il lit |
| --- | --- | --- |
| L’app — code client, auth, hébergement | Votre dépôt | Les pages de `/build/apps/` |
| Le domaine — doctypes, périmètres, actions | Les fichiers `*.facet-domain/` | [Construire des domaines avec un agent de code](/fr/build/model/in-files/with-a-coding-agent/) |

Le corpus de skills de l’assistant embarqué enseigne l’écriture des doctypes
et des vues. Ce corpus ne sert que l’assistant de construction embarqué :
aucune route REST, aucun tool MCP, aucun export ne l’expose à un agent
externe. Un agent externe construit les domaines à partir de la
documentation des fichiers de domaine.

## Exemple

Une session de récupération complète :

```sh
# Une seule petite requête : l’index des jeux de textes.
curl -sL https://docs.facet.example/llms.txt

# Un seul sujet : le jumeau markdown brut d’une page.
curl -sL https://docs.facet.example/build/apps/data/rest-api.md
```

La même récupération en TypeScript. Elle place le texte de la page dans le
contexte de l’agent :

```ts
async function loadFacetPage(path: string): Promise<string> {
	const response = await fetch(`https://docs.facet.example${path}`);
	if (!response.ok) {
		throw new Error(`No page twin at ${path}: HTTP ${response.status}`);
	}
	return response.text();
}

const page = await loadFacetPage('/build/apps/data/rest-api.md');
// Remettez `page` à l’agent comme contexte pour la tâche.
```

## Dépannage

**L’agent invente un endpoint.**

La page manque dans son contexte. Récupérez le jumeau dans son contexte,
puis répétez la demande.

**L’agent écrit du code élidé.**

Les blocs du site sont complets. Demandez à l’agent de copier le bloc, pas
de l’esquisser.

**Un jumeau `.md` répond `404`.**

Les routes de repli françaises n’ont pas de jumeau. Récupérez la page
anglaise.

**Les réponses de l’agent deviennent périmées après un changement de
doctype.**

Récupérez de nouveau les pages qui enseignent ce doctype.

## Voir aussi

- [Construire des domaines avec un agent de code](/fr/build/model/in-files/with-a-coding-agent/) — la moitié domaine : fichiers, watcher, boucle de vérification.
- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — la page que les agents récupèrent le plus.
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/build/apps/data/sdk/) — des appels typés que l’agent peut copier.
- [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/) — le catalogue pour les agents à l’exécution.
- [Référence](/fr/reference/) — la référence d’API lisible par machine.
