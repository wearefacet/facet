---
title: Bâtir des apps avec un agent de code
description: Donnez la documentation de Facet à un agent de code via llms.txt, des pages markdown brutes et des blocs de code complets.
audience: [developer]
features: [AI-06]
sidebar:
  order: 19
verified_at: a77c6171
---

Un agent de code peut construire une app Facet à partir de ce site. Chaque
page existe dans un format que les agents consomment, et la documentation
suit des règles qui rendent fiable ce que l’agent produit. Vous pointez
l’agent vers les bonnes pagesà ; les pages font le reste.

> **Pour les agentsà :** Commencez par récupérer `https://docs.facet.example/llms.txt` —
> il indexe les deux jeux de textes. Un seul sujetà : récupérez la copie de la
> page à `https://docs.facet.example/<path>.md` — par exemple
> `/apps/rest-api.md` — markdown octet pour octet, front-matter conservé.
> Plusieurs sectionsà : `/llms-small.txt` (compact) ou `/llms-full.txt` (toutes
> les pages anglaises dans un seul fichier). Les blocs de code de ce site sont
> complets et exécutables — copiez-lesà ; n’inventez aucun appel.

## Quand l’utiliser

Consultez cette page quandà :

- Vous construisez une app Facet avec un agent de code.
- L’agent invente des endpoints ou des paramètres.
- Vous devez garder le contexte de l’agent léger.

## Avant de commencer

La construction du site sert chaque page deux foisà : la version rendue, et le
markdown brut. Le jeu lisible par une machineà :

| Adresse | Contenu |
| --- | --- |
| `/llms.txt` | L’index des deux autres fichiers |
| `/llms-small.txt` | La documentation abrégée — la plupart des pages, moins de détail |
| `/llms-full.txt` | Le texte complet de chaque page anglaise dans un seul fichier |
| `/<path>.md` | Une page en markdown brut — par exemple `/apps/rest-api.md` |

La copie `.md` est identique octet pour octetà : le front-matter (`audience`,
`features`, `verified_at`) reste en place, et un diagramme reste un commentaire
HTML qui porte sa source D2, à côté de l’image rendue. Le bouton
"Copy as markdown" de chaque page récupère la même copie. Les exemples
ci-dessous utilisent `https://docs.facet.example`, le placeholder de la
configuration du dépôtà ; utilisez l’adresse de la documentation de votre
déploiement.

## Étapes

### 1. Pointer l’agent vers l’index

Récupérez `/llms.txt` d’abord. C’est une seule petite requête, et elle liste
les deux jeux de textes.

### 2. Choisir le jeu de textes

Donnez `/llms-small.txt` à l’agent pour un balayage à petit coût. Donnez-lui
`/llms-full.txt` quand la tâche couvre plusieurs sections.

### 3. Récupérer la copie d’une page pour un sujet précis

Pour une tâche unique, récupérez la copie de la page qui couvre ce sujet, et
placez son texte dans le contexte de l’agent. La section Exemple ci-dessous
porte les commandes.

### 4. Demander la modification

Demandez à l’agent de copier les blocs de code complets que les pages portent,
au lieu d’inventer des appels. Quand un appel échoue, renvoyez l’agent vers la
copie de la page.

## Explication

### Pourquoi les agents réussissent bien sur ce site

La documentation suit des règles d’écriture qui rendent fiable ce que l’agent
produità :

- Chaque bloc de code est complet et exécutable. Aucune élision `...` :
  l’agent peut coller un bloc tel quel.
- Chaque page de `/apps/` ouvre avec un encadré **Pour les agents** :
  endpoints, clés, et séquence d’appels minimale en texte brut.
- Les tables portent les données de référenceà : filtres, erreurs, limites.
- Chaque page enseigne une tâche. Une récupération ciblée vaut mieux qu’une
  large.

### Conseils de prompt

- Donnez les URL de base — site de documentation et instance Facet — plus le
  slug de l’app et le canal d’authentification, avant la tâche.
- Quand un appel échoue, demandez à l’agent de relire la copie de la page. Ne
  le laissez pas deviner les paramètres.
- Quand le contexte est serré, récupérez la page du doctype ou de la route,
  pas le jeu de textes complet.

### Le corpus de skills

L’assistant de construction de domaines embarque des fichiers de skills pour
LLM. Ils enseignent l’écriture des doctypes, des vues et des fixtures. Ce
corpus sert uniquement à l’assistant de construction intégré à l’appà : aucune
route REST, aucun outil MCP, aucun export ne l’expose à un agent externe. Un
agent externe construit les domaines à partir de la documentation REST à la
placeà :

- [domain-builder-skills.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-builder-skills.md)
  — le corpus de skills et la limite de sa portée.
- [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md)
  — les définitions de doctypes.
- [build-a-domain.md](https://github.com/wearefacet/facet/blob/main/doc/ops/build-a-domain.md)
  — le parcours pas à pas de la construction d’un domaine.

## Exemple

Une session de récupération complèteà :

```sh
# Une seule petite requêteà : l’index des jeux de textes.
curl -sL https://docs.facet.example/llms.txt

# Un seul sujetà : la copie markdown brute d’une page.
curl -sL https://docs.facet.example/apps/rest-api.md
```

La même récupération en TypeScript. Elle place le texte de la page dans le
contexte de l’agentà :

```ts
async function loadFacetPage(path: string): Promise<string> {
  const response = await fetch(`https://docs.facet.example${path}`);
  if (!response.ok) {
    throw new Error(`No page twin at ${path}: HTTP ${response.status}`);
  }
  return response.text();
}

const page = await loadFacetPage('/apps/rest-api.md');
// Remettez `page` à l’agent comme contexte pour la tâche.
```

## Dépannage

**L’agent invente un endpoint.**

La page manque dans son contexte. Récupérez la copie dans son contexte, puis
répétez la demande.

**L’agent écrit du code élidé.**

Les blocs du site sont complets. Demandez à l’agent de copier le bloc, pas de
l’esquisser.

**Une copie `.md` répond `404`.**

Les routes de repli françaises n’ont pas de copie. Récupérez la page anglaise.

**Les réponses de l’agent deviennent périmées après un changement de
doctype.**

Récupérez de nouveau les pages qui traitent ce doctype.

## Voir aussi

- [Utiliser l’API REST](/fr/apps/rest-api/) — la page que les agents
  récupèrent le plus.
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/) — des appels
  typés que l’agent peut copier.
- [Outils d’agent](/fr/apps/agent-tools/) — le catalogue pour les agents à

  l’exécution.
- [Référence](/fr/reference/) — la référence d’API lisible par machine.
- Internes sur GitHubà :
  [domain-builder-skills.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-builder-skills.md).
