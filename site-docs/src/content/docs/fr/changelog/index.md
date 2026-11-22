---
title: Versions
description: Comment Facet versionne et publie ses versions, et où lire les notes de version.
audience: [operator, developer]
features: []
sidebar:
  order: 0
verified_at: 7a6cb462
---

Utilisez cette page pour savoir ce que contient une version et où elle
atterrit. Un tag git démarre chaque version, et le préfixe du tag choisit
l’artefact : `v*` publie des images de conteneurs versionnées, et un
préfixe de paquet publie un paquet npm.

## Le principe des versions

Facet livre deux types d’artefacts depuis un seul dépôt :

| Artefact | Déclencheur | Où il atterrit |
| --- | --- | --- |
| Images de conteneurs | un tag git `v*` | GHCR : `ghcr.io/wearefacet/facet`, `ghcr.io/wearefacet/facet-frontend` |
| Paquets npm | un préfixe de tag de paquet (`sdk-v*`, `chat-v*`, `cli-v*`) | le registre npm, plus une GitHub Release |

Les deux pipelines de release passent leurs contrôles :

- **Pipeline conteneurs** — construit et soumet les deux architectures à un
  test de fumée avant que quoi que ce soit n’atteigne le registre.
- **Pipeline npm** — lance lint, la vérification de types et les tests avant
  de publier.

## Images de conteneurs

Un mainteneur pousse un tag `v*`. Le workflow de release construit alors les
images backend et frontend pour amd64 et arm64, fait tourner la pile de tests
de fumée sur les deux architectures, et publie :

| Tag d’image | Signification |
| --- | --- |
| `X.Y.Z` | Une version exacte |
| `X.Y` | La dernière version d’une série mineure |
| `latest` | La dernière version — uniquement des tags de version, jamais des builds de branche |

Un push sur `master` publie le canal glissant : les tags d’image `master`
et `nightly` avancent à chaque build vert. Un test de fumée en échec laisse le
registre intact.

## Paquets npm

Chaque paquet sous `packages/` possède un préfixe de tag, et un tag démarre
exactement une version :

| Tag | Paquet |
| --- | --- |
| `sdk-v*` | `@facetapp/sdk` |
| `chat-v*` | `@facetapp/chat` |
| `cli-v*` | `@facetapp/cli` |

La version du tag doit égaler le champ `version` du `package.json` du
paquet : un tag sans montée de version ne publie rien. Une version avec
un `-`, par exemple `0.0.2-beta.1`, est une préversion : elle se publie
sous le dist-tag `beta` et ne devient jamais `latest`. Chaque version ouvre
une GitHub Release avec des notes générées.

## Notes de version

Lisez les notes de chaque version sur sa GitHub Release. Elles commencent avec
la première version.

## Voir aussi

- Déployez les images de release : [Exploitation](/fr/operate/)
- Le pipeline de construction et de publication des conteneurs (doc du
  dépôt) :
  [doc/ops/container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md)
- Le flux de release des paquets npm (doc du dépôt) :
  [doc/packages/release.md](https://github.com/wearefacet/facet/blob/main/doc/packages/release.md)
