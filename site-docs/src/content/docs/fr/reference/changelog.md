---
type: reference
title: Versions
description: Comment Facet versionne et publie ses versions, et où lire les notes de version.
audience: [operator, developer]
features: []
sidebar:
  order: 20
verified_at: eee55a2
---

Un tag git démarre chaque version, et le préfixe du tag choisit l’artefact :
un tag `v*` publie des images de conteneurs versionnées, et un préfixe de
paquet publie un paquet npm. Le fichier `CHANGELOG.md` à la racine du dépôt
fait foi pour les notes de version.

## Fonctionnement des versions

Facet livre deux types d’artefacts depuis un seul dépôt :

| Artefact | Déclencheur de release | Destination |
| --- | --- | --- |
| Images de conteneurs | un tag git `v*` | GHCR : `ghcr.io/wearefacet/facet`, `ghcr.io/wearefacet/facet-frontend` |
| Paquets npm | un préfixe de tag de paquet (`sdk-v*`, `chat-v*`, `cli-v*`) | le registre npm, plus une GitHub Release |

Les deux pipelines de release passent leurs propres contrôles :

- **Pipeline conteneurs** — construit les deux architectures et les soumet à
  un test de fumée avant que quoi que ce soit n’atteigne le registre.
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

Chaque paquet sous `packages/` possède son préfixe de tag, et un tag démarre
exactement une release :

| Tag | Paquet |
| --- | --- |
| `sdk-v*` | `@facetapp/sdk` |
| `chat-v*` | `@facetapp/chat` |
| `cli-v*` | `@facetapp/cli` |

La version du tag doit égaler le champ `version` du `package.json` du
paquet : un tag sans montée de version ne publie rien. Une version avec
un `-`, par exemple `0.0.2-beta.1`, est une préversion : elle se publie
sous le dist-tag `beta` et ne devient jamais `latest`. La publication passe
par une étape de validation : un mainteneur approuve la version dans la
console npm avant sa mise en ligne. Chaque release ouvre une GitHub Release
avec des notes générées.

## Notes de version

Le fichier `CHANGELOG.md` à la racine du dépôt contient les notes de chaque
release. Il fait foi — cette page n’en reprend pas le contenu. Le projet est
pré-1.0 : une release peut donc contenir des changements incompatibles.
Lisez les notes de déploiement d’une release avant de mettre à jour.

Chaque tag de release ouvre aussi une GitHub Release. Ses notes sont générées
à partir des pull requests fusionnées, pas à partir de `CHANGELOG.md`.

## Voir aussi

- Déployez les images de release : [Exploitation](/fr/admin/)
- Le pipeline de construction et de publication des conteneurs (doc du
  dépôt) :
  [doc/ops/container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md)
- Le flux de release des paquets npm (doc du dépôt) :
  [doc/packages/release.md](https://github.com/wearefacet/facet/blob/main/doc/packages/release.md)
