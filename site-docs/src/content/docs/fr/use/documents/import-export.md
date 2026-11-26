---
title: Importer et exporter des données
description: Déplacer des documents entre Facet et des fichiers CSV ou JSON.
audience: [user, author]
features: [FE-18, DOC-11]
sidebar:
  order: 10
verified_at: 49d7c7e5
---

Chaque page de liste porte « Exporter » et « Importer » dans sa barre
d’outils.

- **Exporter** écrit les documents de la liste dans un fichier CSV (valeurs
  séparées par des virgules) ou JSON (JavaScript Object Notation).
- **Importer** lit un tel fichier et crée ou met à jour des documents.

Les deux tournent en arrière-plan. Facet rapporte le résultat quand le travail
se termine.

## Avant de commencer

- **Exporter** demande l’accès en lecture à la liste.
- **Importer** demande les accès de création et de mise à jour ensemble. Facet
  refuse tout le fichier quand l’un manque.
- **Le fichier le plus sûr** est un fichier que vous avez exporté de la même
  liste.

:::caution
L’import écrit de vrais documents. Facet applique tout le fichier ou rien. La
première ligne en faute arrête l’import, et aucune ligne du fichier n’est
écrite.
:::

## Étapes

### 1. Exportez tous les documents d’une liste

1. Ouvrez la page de liste.
2. Sélectionnez « Exporter » dans la barre d’outils.
3. Sélectionnez « Exporter en CSV » pour un tableur, ou « Exporter en JSON »
   pour une copie structurée complète.
4. Facet démarre un travail en arrière-plan et confirme : « Export
   lancé — le lien vers le fichier arrivera ici dès qu’il sera prêt. »
5. Quand le fichier est prêt, sélectionnez « Télécharger » dans le message. Le
   même lien arrive dans vos notifications.

  Le fichier porte :

- chaque document de la liste que votre compte peut voir
- une colonne `id` en premier, avec l’identifiant de chaque document
- aucun champ que votre rôle cache
- les données telles qu’à un instant donné. Facet lit la liste en un seul
  instantané.

### 2. Exportez la vue tableau courante

L’entrée de menu « CSV — vue actuelle » exporte ce que le tableau montre
maintenant :

- les colonnes que le tableau montre, dans leur ordre
- les filtres et le tri que vous avez appliqués
- les cellules de date et d’heure dans votre fuseau horaire d’affichage

1. Réglez les colonnes, les filtres et le tri sur la liste.
2. Sélectionnez « Exporter », puis « CSV — vue actuelle ».
3. Téléchargez le fichier comme à l’étape 1.

:::note
Un fichier de vue sert à lire, pas à réimporter. Facet écrit ses cellules de
date et d’heure sans zone, si bien qu’un import de ce fichier échoue à la
validation. Utilisez « Exporter en CSV » pour un fichier que vous comptez
importer.
:::

### 3. Importez des documents depuis un fichier

1. Ouvrez la page de liste.
2. Sélectionnez « Importer » dans la barre d’outils.
3. Sélectionnez « Choisir un fichier .csv ou .json », et prenez votre fichier.
4. Facet montre le nombre de lignes et les premiers noms de colonnes.
   Vérifiez-les.
5. Sélectionnez « Importer ». La boîte de dialogue confirme : « Import
   de 12 lignes en cours — le résultat arrivera dans vos notifications. »
6. Vous pouvez fermer la boîte de dialogue et continuer à travailler. Le
   résultat arrive aussi dans vos notifications.

  Un import réussi rapporte, par exemple : **3 créée(s) · 2 mise(s) à

  jour · 1 ignorée(s)**.

  Facet apparie chaque ligne par son `id` :

- Une ligne avec un `id` met à jour le document correspondant.
- Une ligne sans `id` crée un nouveau document. Facet génère l’identifiant.
- Une ligne dont le `id` correspond à un document supprimé est ignorée.
  L’import ne restaure pas les documents supprimés.

:::tip
Pour mettre à jour quelques documents, exportez d’abord la liste. Changez les
cellules dans le fichier, gardez la colonne `id` inchangée, et importez le
fichier à nouveau.
:::

### 4. Déplacez une définition de domaine (auteurs)

Les auteurs peuvent déplacer une définition de domaine entière entre
instances. Dans l’espace Configurer, ouvrez la liste des domaines. Le menu de
ligne d’un domaine publié porte « Exporter le bundle ». Le bouton « Importer
un bundle » dans l’en-tête de la page applique un bundle téléchargé. Vous pouvez l’importer sous un nouveau nom, ou le
fusionner dans un domaine existant. Un bundle porte seulement des
définitions. Les documents ne voyagent pas avec lui. Voir
[Construire des domaines](/fr/build/).

## Exemple

Vous pouvez aussi exporter par l’API (interface de programmation). Créez
d’abord une clé d’API dans « Paramètres → Clés API ». Votre rôle doit permettre
l’accès d’API. La commande ci-dessous lit la clé depuis la variable
d’environnement `FACET_API_KEY`.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/crm/Company/export?format=csv&wait=true" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -o companies.csv
```

`wait=true` fait que Facet envoie le fichier terminé comme réponse. La
commande l’écrit dans `companies.csv`. `-k` saute la vérification du
certificat de l’adresse de développement locale. Sans `wait=true`, Facet
démarre le travail et répond avec l’identifiant du travail. Le lien de
téléchargement arrive alors dans vos notifications.

Un export de la liste CRM d’exemple démarre comme ceci :

```csv
id,logo,name,phone,status,address,website,industry,owner_id,domain_name,search_text,company_size,annual_revenue
crm.Company.1,,Acme Corp,'+1-555-0100,lead,"{""zip"":""94105"",""city"":""San Francisco"",""street"":""100 Innovation Drive"",""country"":""USA""}",https://acme.com,technology,iam.Account.account_recruiter_kim,acme.com,,201-1000,USD 50000000
```

Deux règles de cellule se voient ici. Le `'` devant le numéro de téléphone est
le garde-fou de formule. Facet l’écrit devant un texte qui commence par `=`,
`+`, `-` ou `@`, pour qu’un tableur affiche le texte au lieu de l’évaluer. Une
cellule de montant porte sa devise : `USD 50000000`.

## Limites

| Limite | Règle |
| --- | --- |
| Taille de fichier | Un fichier de plus de 50 Mo est refusé. 50 Mo est la valeur par défaut ; votre instance peut différer. |
| Fenêtre de téléchargement | Facet garde les fichiers d’export 30 jours par défaut. Après, le lien cesse de fonctionner. |
| Clé d’appariement | La colonne `id` est la seule clé d’appariement. Facet ne peut pas apparier par nom ni par un autre champ. |
| Champs de fichier | Un champ de fichier s’exporte comme son identifiant seul. Le contenu du fichier ne voyage pas. |
| Sidecars et enfants | Commentaires, pièces jointes, documents enfants et autres données sidecar ne voyagent pas ainsi. |

Règles de cellule pour le fichier :

- Une cellule de montant demande la devise : `USD 10`.
- Une cellule vide efface le champ à la mise à jour. Une colonne que vous
  omettez laisse le champ inchangé.
- Facet écrit un `'` devant un texte qui commence par `=`, `+`, `-` ou `@`.
  L’import retire un `'` de tête.
- Un document écrit avant le dernier changement de la définition de la liste
  s’exporte dans sa forme stockée plus ancienne.

## Dépannage

### Rien n’a été importé, et un message de ligne nomme un champ

Par exemple : « Rien n’a été importé. » avec « Ligne 3, champ amount :
… ».

Une ligne a échoué à la validation. Rien n’a été écrit. Corrigez cette ligne
et soumettez le fichier à nouveau.

### La forme du fichier ne correspond pas à l’en-tête

Par exemple : « Ligne 2 : row has 3 cells but the header declares 2
columns ».

Facet vérifie la forme du fichier avant que le travail ne démarre. Le message
nomme la ligne en faute. Corrigez la ligne, puis importez à nouveau.

### L’export a échoué

Par exemple : « Échec de l’export — consultez les notifications pour
connaître l’erreur. »

Le travail a échoué après son démarrage.

1. Ouvrez « Notifications » et lisez l’erreur là.
2. Corrigez la cause et exportez à nouveau.

### Le lien Télécharger ne fonctionne plus

Le fichier a expiré. Facet garde les fichiers d’export pendant une fenêtre
limitée. Exportez à nouveau.

### Le rapport compte des lignes ignorées

Ces valeurs de `id` correspondent à des documents supprimés. L’import ne
restaure pas les documents supprimés.

1. Restaurez-les d’abord depuis la corbeille.
2. Importez à nouveau.

## Voir aussi

- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  la vue courante décide de ce que « CSV — vue actuelle » exporte.
- [Notifications](/fr/use/notifications/) — les travaux terminés y
  livrent le lien de téléchargement.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — chaque ligne
  importée apparaît dans l’historique du document.
- [Paramètres, sessions et clés API](/fr/use/account/) —
  créez la clé d’API pour l’exemple en ligne de commande.
- [Construire des domaines](/fr/build/) — pour les auteurs : où vivent
  l’import et l’export de bundle.
