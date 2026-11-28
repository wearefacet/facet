---
type: how-to
title: Le watcher de domaines
description: Modifiez les fichiers de définition sur le disque et laissez le watcher appliquer chaque enregistrement.
audience: [developer]
features: [DOM-19]
sidebar:
  order: 0
verified_at: eee55a2
---

Le watcher de domaines de dev surveille un dossier de fichiers de domaines
et applique chaque changement à un serveur de dev en cours d’exécution.
Vous modifiez le YAML dans votre éditeur et enregistrez ; le serveur met à
jour les domaines un instant plus tard. Aucun clic dans l’interface, aucun
appel d’API, aucun redémarrage.

## Quand l’utiliser

- Vous développez un domaine dans des fichiers sous gestion de versions.
- Vous voulez des changements relisibles en revue plutôt que des clics
  dans l’éditeur.
- Vous travaillez avec des agents de code IA qui écrivent des fichiers de
  domaines.

## Avant de commencer

- **Un serveur de dev qui vous appartient.** Montez-en un avec le pas à
  pas [Installer l’environnement de dev](/fr/build/dev-environment/).
  Le watcher ne tourne jamais en production ; le code de démarrage y
  refuse de le lancer, même quand la section de configuration est
  présente.
- **Un dossier que le serveur peut lire.** Ajoutez la section
  `dev.domain_watch` à votre configuration de dev :

```yaml
dev:
  domain_watch:
    path: ./dev
    poll_ms: 500
    documents: preserve
```

:::tip
`facet-cli setup-dev` écrit cette section pour vous : il crée un dossier
`domains/`, le monte dans le backend et fait pointer
`dev.domain_watch.path` dessus. Répondez à la question de surveillance
avec un dossier, ou passez `--watch <dir>`, et le watcher est actif au
prochain démarrage. Sur une pile en conteneurs, le chemin dans la
configuration est le chemin du conteneur (`/watch`), tandis que le
dossier que vous modifiez est `./domains` sur l’hôte.
:::

| Clé | Défaut | Signification |
| --- | --- | --- |
| `path` | requis | Le dossier qui porte un sous-dossier par domaine. Un chemin manquant fait échouer le démarrage. |
| `poll_ms` | `500` | La fréquence de scrutation du dossier. La borne basse est `100`. |
| `documents` | `preserve` | `preserve` garde les documents que vous avez créés dans l’app. `discard` reconstruit tout depuis les fichiers à chaque changement. |

:::caution
La ligne de configuration vaut consentement : chaque synchronisation
remplace les définitions des domaines surveillés et, en mode `discard`,
leurs documents aussi. Pointez `path` vers un dossier qui vous appartient.
:::

## Les deux modes documents

| | `preserve` (défaut) | `discard` |
| --- | --- | --- |
| Ce qu’une synchronisation remplace | Les définitions seulement | Les définitions et chaque document |
| Ce qui survit | Les documents que vous avez créés dans l’app, vos vues de liste enregistrées, les fichiers téléversés | Rien ; chaque cycle reconstruit depuis les fichiers |
| Documents d’exemple du bundle | Ne remplissent que les lignes manquantes | Rejoués à neuf à chaque cycle |
| Un doctype qui quitte le bundle | Ses documents sont marqués comme supprimés | Ses documents sont marqués comme supprimés |

`discard` convient aux tests avec des données d’exemple figées :
enregistrez, et le domaine est exactement ce que disent les fichiers.
`preserve` convient au travail quotidien : vos enregistrements créés dans
l’app restent. Dans les deux modes, un doctype qui quitte le bundle emporte
ses documents — sans quoi la relecture recréerait des lignes depuis un
arbre `documents/` périmé.

## Étapes

### 1. Disposer un dossier par domaine

Chaque sous-dossier direct du chemin surveillé porte un bundle de domaine.
La disposition suit le même format qu’une exportation écrit — voir
[La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/)
pour chaque fichier.

```
dev/
└── acme.facet-domain/
    ├── bundle.yml
    ├── domain.yml
    └── doctypes/
        └── acme.Project.yml
```

Le nom du sous-dossier est libre ; le nom du domaine vient de
`bundle.yml` :

```yml
format_version: 2
source_domain: acme
exported_at: "2026-11-13T09:00:00Z"
facet_version: 0.2.2
```

### 2. Enregistrer et laisser faire le watcher

Enregistrez n’importe quel fichier. Dans un cycle de scrutation ou deux,
le serveur applique le dossier : il lit le bundle, remplace les
définitions et rapporte une ligne par domaine dans le journal du serveur :

```text
[dev-sync] synced 'acme' from 'dev/acme.facet-domain': 1 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

Un bundle ajouté pendant que le serveur tourne est ramassé à la
scrutation suivante. Le watcher attend le calme : un enregistrement qui
arrive en plusieurs écritures de fichiers ne s’applique qu’une fois. Un
enregistrement qui ne change rien (mêmes contenus de fichiers) ne fait
rien — la détection de changement porte sur le contenu, pas sur
l’horloge.

### 3. Lire les diagnostics

Après chaque synchronisation, le watcher exécute le même service de
vérification que le Builder. Un domaine propre ne journalise rien. Un
domaine avec des anomalies journalise une ligne, et le rapport complet est
à un endpoint :

```text
[dev-sync] check for 'acme': 2 issue(s) — first: Reference field 'customer' … — full report: GET /Api/dev/check-report?domain=acme
```

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/dev/check-report?domain=acme"
```

La route n’existe que sur un serveur de dev ; en production elle répond
`404`. Voir [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/)
pour la forme du rapport.

En mode `preserve`, chaque doctype dont les champs ont changé pendant
qu’il détient encore des documents journalise un avertissement de
structure, et le watcher re-projette les lignes conservées pour que leurs
libellés et leur texte de recherche suivent les nouvelles définitions.
Une modification de composition ou une modification limitée aux actions
reste silencieuse.

## Quand un fichier est cassé

Un fichier qui ne s’analyse pas, ou une définition qui échoue à la
validation, ne met jamais le domaine à bas. Le démontage et l’import d’une
même synchronisation partagent une transaction : un import qui échoue
ramène les deux en arrière. Le domaine garde son état précédent, et le
journal nomme le fichier et le champ :

```text
[dev-sync] import for 'acme' (dev/acme.facet-domain) failed: 422 acme.Widget: schema validation failed — keeping previous state
  details:
    - field: fields.name
      message: must be a lowercase snake_case identifier
```

Corrigez le fichier et enregistrez de nouveau. Les domaines voisins ne
sont pas touchés — l’isolation des pannes est par bundle. Un dossier de
bundle que vous supprimez avertit une fois et conserve le dernier état
synchronisé du domaine ; rien ici ne supprime un domaine en direct.

## Exemple

Vous ajoutez un champ priority au doctype Project :

```yml
    priority:
      type: string
      title: Priority
```

Vous enregistrez. La ligne de journal rapporte la synchronisation de acme
avec ses compteurs d’import. Vous ouvrez l’app en cours d’exécution : le
formulaire Project affiche déjà le nouveau champ. Comme le mode est
`preserve`, les projets créés pendant vos tests sont toujours là.

## Dépannage

**Rien ne se passe quand j’enregistre.**

La section manque peut-être à la configuration, le chemin n’existe
peut-être pas, ou le sous-dossier n’a pas de `bundle.yml`. Un sous-dossier
sans ce fichier est ignoré.

**La synchronisation échoue à chaque enregistrement.**

Lisez les erreurs de champ journalisées ; elles nomment le fichier et le
champ. Le domaine reste dans son état précédent : vous corrigez le
fichier pendant que l’app tourne.

**Le même domaine apparaît deux fois.**

Deux sous-dossiers déclarent le même nom de domaine dans `bundle.yml`.
Gardez-en un ; le journal nomme les deux répertoires à chaque cycle.

**Un redémarrage avertit du remplacement d’un domaine.**

Le premier démontage d’un domaine que ce processus de watcher n’a pas
créé avertit de façon distincte — après un redémarrage, cela vaut pour
chaque domaine. C’est un garde-fou contre un `path` pointé vers le
mauvais dossier, pas une panne.

## Voir aussi

- [La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/) — chaque fichier que le watcher lit.
- [Bâtir des domaines avec un agent](/fr/build/model/in-files/with-a-coding-agent/) — la boucle de l’agent au-dessus du watcher.
- [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/) — le rapport de vérification, en entier.
- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — envoyer le dossier terminé vers une autre instance.
- Doc interne sur GitHub : [dev-domain-watcher.md](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md).
- [Choisir sa façon de construire](/fr/build/model/)
