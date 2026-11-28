---
type: how-to
title: Importer et exporter des données
description: Importez des documents depuis des fichiers CSV ou JSON, et exportez ce qu’affiche une liste.
audience: [user]
features: [FE-18, DOC-11]
sidebar:
  order: 4
verified_at: eee55a2
---

Chaque page de liste porte **Exporter** et **Importer** dans sa barre
d’outils.

![A clients list with the Export and Import controls in the toolbar.](/screens/use/documents-4.png)

- **Exporter** écrit les documents de la liste dans un fichier CSV (valeurs
  séparées par des virgules) ou JSON (JavaScript Object Notation).
- **Importer** lit un tel fichier et crée ou met à jour des documents.

Les deux tournent en arrière-plan. Facet rapporte le résultat quand le
travail se termine.

## Avant de commencer

- **Exporter** demande l’accès en lecture à la liste.
- **Importer** demande les accès de création et de mise à jour ensemble.
  Facet refuse tout le fichier quand l’un manque.
- **Le fichier le plus sûr** est un fichier que vous avez exporté de la même
  liste.

:::caution
L’import écrit de vrais documents. Facet applique tout le fichier ou rien.
La première ligne en faute arrête l’import, et aucune ligne du fichier n’est
écrite.
:::

## Étapes

### 1. Exportez tous les documents d’une liste

1. Ouvrez la page de liste.
2. Sélectionnez **Exporter** dans la barre d’outils.
3. Sélectionnez **Exporter en CSV** pour un tableur, ou **Exporter en JSON**
   pour une copie structurée complète.
4. Facet démarre un travail en arrière-plan et confirme : *« Export lancé —
   le lien vers le fichier arrivera ici dès qu’il sera prêt. »*
5. Quand le fichier est prêt, sélectionnez **Télécharger** dans le message.
   Le même lien arrive dans vos notifications.

Le fichier contient :

- chaque document de la liste que votre compte peut voir
- une colonne `id` en premier, avec l’identifiant de chaque document
- aucun champ que votre rôle cache
- les données telles qu’à un instant donné. Facet lit la liste en un seul
  instantané.

### 2. Exportez la vue tableau courante

L’entrée de menu **CSV — vue actuelle** exporte ce que le tableau montre
maintenant :

- les colonnes que le tableau montre, dans leur ordre
- les filtres et le tri que vous avez appliqués
- les cellules de date et d’heure dans votre fuseau horaire d’affichage

1. Réglez les colonnes, les filtres et le tri sur la liste.
2. Sélectionnez **Exporter**, puis **CSV — vue actuelle**.
3. Téléchargez le fichier comme à l’étape 1.

:::note
Un fichier de vue sert à lire, pas à réimporter. Facet écrit ses cellules de
date et d’heure sans zone, si bien qu’un import de ce fichier échoue à la
validation. Utilisez **Exporter en CSV** pour un fichier que vous comptez
importer.
:::

### 3. Importez des documents depuis un fichier

1. Ouvrez la page de liste.
2. Sélectionnez **Importer** dans la barre d’outils.
3. Sélectionnez **Choisir un fichier .csv ou .json**, et prenez votre
   fichier.
4. Facet montre le nombre de lignes. Vérifiez-le.
5. Sélectionnez **Importer**. La boîte de dialogue confirme : *« Import de
   12 lignes en cours — le résultat arrivera dans vos notifications. »*
6. Vous pouvez fermer la boîte de dialogue et continuer à travailler. Le
   résultat arrive aussi dans vos notifications.

Un import réussi rapporte, par exemple : **3 créée(s) · 2 mise(s) à
jour · 1 ignorée(s)**.

Facet apparie chaque ligne par son `id` :

- Une ligne avec un `id` met à jour le document correspondant.
- Une ligne sans `id` crée un nouveau document. Facet génère l’identifiant.
- Une ligne dont l’`id` correspond à un document supprimé est ignorée.
  L’import ne restaure pas les documents supprimés.

:::tip
Pour mettre à jour quelques documents, exportez d’abord la liste. Changez les
cellules dans le fichier, gardez la colonne `id` inchangée, et importez le
fichier à nouveau.
:::

### 4. Déplacez un domaine entier (auteurs)

Les auteurs de domaine peuvent déplacer la structure d’un domaine entre
instances. Dans l’espace **Configurer**, ouvrez la liste des domaines :
**Exporter le bundle** se trouve dans le menu de ligne d’un domaine publié,
et **Importer un bundle** dans l’en-tête de la page. Un import peut créer le
domaine sous un nouveau nom, ou fusionner dans un domaine existant. Un bundle
ne porte que des définitions — les documents ne voyagent pas avec lui. Voir
[Déplacer des domaines avec des bundles](/fr/build/model/bundles/).

## Bons fichiers et mauvais fichiers

Deux règles de cellule comptent quand vous modifiez un fichier exporté dans
un tableur :

- **Les cellules de montant portent leur devise**, par exemple `EUR 1200`.
  Gardez la devise quand vous modifiez.
- **Un texte qui commence par un symbole peut porter un garde-fou.** Facet
  écrit un `'` de tête devant un texte qui commence par `=`, `+`, `-` ou `@`,
  pour qu’un tableur affiche le texte au lieu de le traiter comme une
  formule. L’import retire un `'` de tête. Laissez-le tel quel.

Autres règles pour le fichier :

- Une cellule vide efface le champ à la mise à jour. Une colonne que vous
  omettez laisse le champ inchangé.
- Un champ de fichier s’exporte comme son identifiant seul. Le contenu du
  fichier ne voyage pas.
- Les commentaires, les pièces jointes, les documents enfants et les autres
  données de panneau ne voyagent pas ainsi.
- Un document écrit avant le dernier changement de la définition de la liste
  s’exporte dans sa forme stockée plus ancienne.

| Limite | Règle |
| --- | --- |
| Taille de fichier | Un fichier de plus de 50 Mo est refusé. 50 Mo est la valeur par défaut ; votre instance peut différer. |
| Fenêtre de téléchargement | Facet garde les fichiers d’export 30 jours par défaut. Après, le lien cesse de fonctionner. |
| Clé d’appariement | La colonne `id` est la seule clé d’appariement. Facet ne peut pas apparier par nom ni par un autre champ. |

## Exemple

Chez Brightwater, l’ancien tableur d’équipements devient Items. Lucía exporte
la liste Item avec **Exporter en CSV**, colle les lignes de l’ancien tableur
dans le fichier, retire les cellules `id` (chaque ligne sans `id` crée un
nouvel enregistrement), et importe le fichier sur la liste Item. Le rapport
dit **40 créée(s) · 0 mise(s) à jour · 0 ignorée(s)**, et la colonne des
numéros de série reste unique — un numéro en double arrêterait tout le
fichier.

Chaque ligne importée apparaît dans l’historique des documents sous le nom
*import*, si bien que vous pouvez toujours retracer ce qu’un fichier a
changé.

## Dépannage

### Rien n’a été importé, et un message de ligne nomme un champ

Par exemple : *« Rien n’a été importé. »* avec *« Ligne 3, champ amount :
… »*.

Une ligne a échoué à la validation. Rien n’a été écrit. Corrigez cette ligne
et soumettez le fichier à nouveau.

### La forme du fichier ne correspond pas à l’en-tête

Par exemple : *« row 2: has 3 cells but the header declares 2 columns »*.

Facet vérifie la forme du fichier avant que le travail ne démarre. Le
message nomme la ligne en faute. Corrigez la ligne, puis importez à nouveau.
La même vérification préalable refuse les colonnes que la liste ne connaît
pas.

### L’export a échoué

Par exemple : *« Échec de l’export — consultez les notifications pour
connaître l’erreur. »*

Le travail a échoué après son démarrage.

1. Ouvrez **Notifications** et lisez l’erreur.
2. Corrigez la cause et exportez à nouveau.

### Le lien Télécharger ne fonctionne plus

Le fichier a expiré. Facet garde les fichiers d’export pendant une fenêtre
limitée. Exportez à nouveau.

### Le rapport compte des lignes ignorées

Ces valeurs d’`id` correspondent à des documents supprimés. L’import ne
restaure pas les documents supprimés.

1. Restaurez-les d’abord depuis la corbeille.
2. Importez à nouveau.

## Voir aussi

- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  la vue courante décide de ce que **CSV — vue actuelle** exporte.
- [Notifications](/fr/use/notifications/) — les travaux terminés y livrent
  le lien de téléchargement.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — chaque
  ligne importée apparaît dans l’historique du document.
- [Import/export en masse via l’API](/fr/build/apps/data/bulk-import-export/) —
  les mêmes opérations via l’API, pour les apps et les scripts.
- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — pour
  les auteurs : l’import et l’export de bundle en détail.
