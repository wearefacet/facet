---
title: Le watcher de domaines en dev
description: Modifiez les fichiers de définition de domaines sur le disque et laissez le serveur de dev les appliquer.
audience: [author, developer]
features: [DOM-19]
sidebar:
  order: 26
verified_at: fd345fe3
---

Le watcher de domaines surveille un dossier de fichiers de domaines et
applique chaque changement à un serveur de dev en cours d’exécution. Vous
modifiez le YAML dans votre éditeur et enregistrezà ; le serveur met à jour les
domaines un instant plus tard. Aucun clic dans l’interface, aucun appel d’API,
aucun redémarrage.

## Quand l’utiliser

- Vous développez un domaine dans des fichiers sous gestion de versions.
- Vous voulez des changements relisibles en revue plutôt que des clics dans l’éditeur.
- Vous travaillez avec des agents de code qui écrivent des fichiers de domaines.

## Avant de commencer

- **Un serveur de dev qui vous appartient.** Le watcher ne tourne jamais en
  productionà ; le serveur y refuse de le démarrer.
- **Un dossier que le serveur peut lire.** Ajoutez la section `dev.domain_watch`
 à votre configuration de devà :

```yaml
dev:
  domain_watch:
    path: ./dev
    poll_ms: 500
    documents: preserve
```

| Clé | Défaut | Signification |
| --- | --- | --- |
| `path` | requis | Le dossier qui porte un sous-dossier par domaine. |
| `poll_ms` | `500` | La fréquence de scrutation du dossier. |
| `documents` | `preserve` | `preserve` garde les documents que vous avez créés dans l’app. `discard` reconstruit tout depuis les fichiers à chaque changement. |

:::caution
La ligne de configuration vaut consentementà : chaque synchronisation remplace
les définitions des domaines surveillés et, en mode `discard`, leurs documents
aussi. Pointez `path` vers un dossier qui vous appartient.
:::

## Étapes

### 1. Disposer un dossier par domaine

Chaque sous-dossier direct du chemin surveillé porte un bundle de domaineà :

```
dev/
└── acme.facet-domain/
    ├── bundle.yml
    ├── domain.yml
    └── doctypes/
        └── acme.Project.yml
```

Le nom du sous-dossier est libreà ; le nom du domaine vient de `bundle.yml` :

```yml
format_version: 2
source_domain: acme
exported_at: "2026-11-13T09:00:00Z"
facet_version: 0.1.0
```

`domain.yml` porte le document du domaine — un bloc `content` avec le libellé
et la description, et un `meta` vide. Chaque fichier de `doctypes/` est une
définition de doctypeà :

```yml
content:
  doctype: Project
  domain: acme
  schema_version: 1
  aggregate_root: true
  label: Project
  display_name: "{{ name }}"
  fields:
    name:
      type: string
      required: true
meta:
  parent_id: acme
```

### 2. Enregistrer et laisser faire le watcher

Enregistrez n’importe quel fichier. Dans un cycle de scrutation ou deux, le
serveur applique le dossierà : il lit le bundle, remplace les définitions et
rapporte une ligne par domaine dans le journal du serveur. Un bundle ajouté
pendant que le serveur tourne est ramassé à la scrutation suivante. Le watcher
attend que l’activité cesseà ; un enregistrement qui arrive en plusieurs
écritures de fichiers ne s’applique qu’une fois.

Après chaque synchronisation, le serveur lance la vérification du domaine et
journalise le compteur d’anomalies. Pour le rapport complet, interrogez la
route du rapport de devà :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/dev/check-report?domain=acme"
```

Une synchronisation qui échoue à la validation journalise les erreurs de champ
exactes, et le domaine garde son état précédent jusqu’au prochain
enregistrement valide.

Avec `preserve`, les documents que vous avez créés dans l’app survivent à une
synchronisation, et les documents d’exemple du bundle ne remplissent que les
lignes manquantes. Avec `discard`, chaque synchronisation reconstruit le
domaine depuis les fichiers — ce qui convient aux tests avec des données
d’exemple figées.

## Exemple

Vous ajoutez un champ `priority` au doctype Projectà :

```yml
    priority:
      type: string
      title: Priority
```

Vous enregistrez. La ligne de journal rapporte la synchronisation de acme avec
ses compteurs d’import. Vous ouvrez l’app en cours d’exécution : le formulaire
Project affiche déj à le nouveau champ. Comme le mode est `preserve`, les
projets créés pendant vos tests sont toujours là.

## Dépannage

**Rien ne se passe quand j’enregistre.**

La section manque peut-être à la configuration, le chemin n’existe peut-être
pas, ou le sous-dossier n’a pas de `bundle.yml`. Un sous-dossier sans ce
fichier est ignoré.

**La synchronisation échoue à chaque enregistrement.**

Lisez les erreurs de champ journaliséesà ; elles nomment le fichier et le
champ. Le domaine reste dans son état précédent, et vous corrigez le fichier
pendant que l’app tourne.

**Le même domaine apparaît deux fois.**

Deux sous-dossiers déclarent le même nom de domaine. Gardez-en unà ; le
journal nomme les deux.

## Voir aussi

- [Watcher de domaines, doc sur GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md) — le contrat de surveillance complet.
- [Évolution du schéma](/fr/concepts/schema-evolution/) — comment les définitions changent avec le temps.
- [Déplacer des domaines avec des bundles](/fr/build/bundles/) — envoyer le dossier terminé vers une autre instance.
