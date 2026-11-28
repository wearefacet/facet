---
type: tutorial
title: Modéliser votre premier domaine
description: Construire le domaine `equipment` de Brightwater dans un brouillon — doctypes, champs, kanban — le vérifier, puis le publier comme domaine réel.
audience: [author]
features: [DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03, AI-02]
sidebar:
  order: 2
verified_at: 11202ad
---

Vous modélisez le domaine `equipment` de Brightwater : les catégories de
matériel, les articles eux-mêmes, et les tickets de maintenance qui les
maintiennent en état de marche. Vous le construisez dans un brouillon,
l’essayez sur un tableau kanban, et le publiez comme domaine réel. Le
brouillon tient chaque expérimentation à l’écart des données réelles jusqu’à
la publication.

**Vous construisez :** le domaine `equipment` de Brightwater — trois doctypes,
des champs typés et un tableau kanban des tickets de maintenance.
**Durée :** environ 20 minutes.
**Prérequis :** [Facet en marche et l’administrateur
connecté](/fr/build/first-hour/run-facet/) — le tutoriel 1 se termine là. La
création de domaines demande un compte administrateur, et le rôle `admin`
pré-créé le possède. Sur une instance `setup-dev`, c’est `admin@example.tld` /
`admin`.

*Le chemin que votre domaine suit, d’un brouillon privé à l’espace de
travail réel.*

<!-- d2
direction: down
draft: "Open a draft"
model: "Add doctypes and fields"
preview: "Try it in Preview"
check: "Check"
publish: "Publish"
live: "Live domain" {class: ok}
draft -> model
model -> preview
preview -> check
check -> model: fix
check -> publish: clean
publish -> live
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/f5f3c4f4-light.svg" alt="Open a draft" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/f5f3c4f4-dark.svg" alt="Open a draft" loading="lazy" />
</div>

## 1. Ouvrez le Builder et créez un brouillon

Ouvrez « Builder » dans la barre latérale. La page d’accueil liste vos
brouillons en cours ; la barre latérale du Builder porte les actions. Cliquez
sur « Nouveau domaine » et remplissez le

![The New domain dialog in the Builder: a Label field, a Domain id field with the rule that the id is permanent once the domain is published, and Cancel and Create draft buttons.](/screens/build/first-domain-4.png)

dialogue :

- **Libellé** : `Equipment` — le nom que tout le monde voit dans l’interface.
- **ID du domaine** : `equipment` — le nom permanent que le domaine reçoit à
  la publication. Lettres minuscules, chiffres et tirets.

Cliquez sur « Créer le brouillon ».

Le brouillon s’ouvre sur sa vue d’ensemble. L’en-tête montre « Equipment »,
un identifiant temporaire qui commence par `_` (par exemple
`_06h1gc0yjgkj`), et un badge « brouillon ». La barre d’onglets lit Vue
d’ensemble / Doctypes / Éditeurs / Octrois / Vérification. Tout ce que vous
construisez maintenant reste dans cette zone de travail privée.

:::note
**Avez-vous un modèle connecté ?** L’assistant de construction de domaine peut
proposer tout le brouillon à partir d’une description en langage naturel —
« un domaine d’entrepôt avec des catégories, des articles et des tickets de
maintenance ». L’assistant est bien plus rapide que les étapes manuelles, et
vous examinez sa proposition dans les mêmes éditeurs que ce tutoriel utilise.
Un modèle doit être connecté d’abord : un administrateur règle l’endpoint et
la clé API dans les paramètres système — voir
[Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/), qui
conseille aussi le modèle à choisir. Sans modèle, suivez les étapes manuelles
ci-dessous ; elles ne demandent rien de plus. Voir
[Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/).
:::

## 2. Ajoutez le doctype Category

Cliquez sur « Ajouter un doctype » dans la barre latérale, tapez `Category`,
puis cliquez sur « Créer le doctype ». L’éditeur de doctype s’ouvre sur
l’onglet Champs.

Cliquez sur « Ajouter un champ ». Un champ nommé `new_field` apparaît.
Réglez-le dans le panneau de droite :

- **Clé** : `name`
- **Type** : String
- **Titre** : `Name`
- **Requis** : activé

Cliquez sur « Enregistrer » dans l’en-tête. Le message flash « Enregistré »
confirme l’écriture. Les modifications restent locales jusqu’à cet
enregistrement — un rechargement les perd.

Un document a besoin d’un libellé. Ouvrez l’onglet « Général », faites
défiler jusqu’à « Modèles de document », réglez le « Modèle de libellé » sur
`{{ name }}`, et enregistrez. Chaque catégorie s’affiche alors par son nom
dans chaque liste et chaque lien.

Vous devez voir un champ, `name`, marqué requis par un astérisque.

## 3. Ajoutez le doctype Item

Cliquez de nouveau sur « Ajouter un doctype », tapez `Item`, puis cliquez sur
« Créer le doctype ». Ajoutez cinq champs, en enregistrant après chacun :

| Clé | Type | Réglages |
| --- | --- | --- |
| `name` | String | Titre `Name`, « Requis » activé |
| `category` | Reference | Titre `Category` ; doctype cible `Category` |
| `status` | Enum | Titre `Status` ; valeurs `available`, `out`, `in_repair` |
| `purchase_price` | Money | Titre `Purchase price` |
| `serial_number` | String | Titre `Serial number` ; « Unique » activé |

![Adding the category field on the Item doctype: the field editor with Key and Title, the Type list open on String, and the Filter capabilities chips below.](/screens/build/first-domain-5.png)

Quatre d’entre eux méritent un mot :

- **Enum** porte un ensemble de valeurs fixé. Tapez chaque clé de valeur dans
  la zone `+ value` et appuyez sur Entrée — l’interface montre un libellé
  lisible, si bien que `available` s’affiche comme Available. Seuls les champs
  enum et booléen peuvent regrouper un tableau kanban ; voilà pourquoi les
  états utilisent ce type.
- **Reference** pointe vers un autre doctype. À la validation, l’éditeur
  qualifie la cible nue avec l’identifiant du brouillon —
  `_06h1gc0yjgkj.Category` dans cette exécution. La publication la réécrit en
  `equipment.Category` ; la forme qualifiée est donc correcte telle quelle.
- **Money** stocke un montant avec une devise. L’éditeur demande d’où vient la
  devise ; les valeurs par défaut conviennent pour l’instant.
- **Unique** refuse un second document avec la même valeur — deux articles ne
  partagent jamais un numéro de série.

Réglez le « Modèle de libellé » sur `{{ name }}` dans l’onglet « Général » et
enregistrez. Vous devez voir cinq champs ; la liste montre une pastille de
type sur chacun — string, reference, enum, money, string.

## 4. Ajoutez le doctype MaintenanceTicket

Créez le doctype de la même façon. Ses champs :

| Clé | Type | Réglages |
| --- | --- | --- |
| `item` | Reference | Titre `Item` ; doctype cible `Item` ; « Requis » activé |
| `problem` | Long Text | Titre `Problem` ; « Requis » activé |
| `status` | Enum | Titre `State` ; valeurs `reported`, `diagnosing`, `waiting_parts`, `fixed` |

Deux remarques :

- Le sélecteur **Default ★ marks the default**, placé sous les pastilles de
  valeurs, choisit la valeur avec laquelle un nouveau document commence.
  Choisissez `reported`.
- La clé `status` avec le titre `State` est délibérée. `state` est un nom
  réservé, et l’enregistrement le refuse avec « Ce nom de champ est réservé et
  ne peut pas être utilisé ». Les noms réservés incluent `state`, `id`,
  `version` et `links`.

Réglez le « Modèle de libellé » sur `{{ item }}` — un ticket affiche l’article
dont il traite — et enregistrez. Vous devez voir trois champs, `item` et
`problem` marqués requis.

## 5. Essayez le modèle dans l’Aperçu

Cliquez sur « Aperçu » dans la barre supérieure. L’espace de travail s’ouvre
avec un bandeau — « Aperçu du brouillon … — les modifications de schéma ne
sont pas disponibles ici » — et les doctypes de votre brouillon dans la barre
latérale. Rien ici ne touche les données réelles.

Ouvrez la liste **MaintenanceTicket**. Un doctype neuf n’a pas de vues ; la
page montre donc l’écran de démarrage : une carte par disposition. Choisissez
« Kanban » — « Cartes regroupées en colonnes ».

La boîte de dialogue « Nouvelle vue » demande :

![The New view dialog for a kanban view: Name, the Scope choice between Personal and General, Board mode with By field values and Custom lanes, Group by, Allow card moves, and Card sort.](/screens/build/first-domain-6.png)

- **Nom** : `Board`
- **Portée** : « Générale » — chaque lecteur du doctype voit cette vue. Le
  choix est fixé après l’enregistrement.
- **Mode du tableau** : « Par valeurs de champ » — une colonne par valeur du
  champ choisi.
- **Regrouper par** : `State`. Chaque valeur du champ devient une colonne.

Cliquez sur « Créer la vue ». Quatre colonnes s’ouvrent — Reported,
Diagnosing, Waiting for parts, Fixed — toutes vides.

Nourrissez maintenant le tableau. Le formulaire de ticket exige un article, et
le formulaire d’article exige une catégorie ; créez-les donc dans cet ordre,
via le bouton « Nouveau » de chaque liste :

| Liste | Documents |
| --- | --- |
| Category | `Tents` |
| Item | `Main tent 10x15` (Tents), `Folding chair white` (Tents) |
| MaintenanceTicket | trois tickets, un par état : `reported` avec le problème « Zip seam splits under load », `diagnosing` avec « Frame pin sheared », `fixed` avec « Loose guy-line clip replaced » |

Chaque carte de ticket montre le nom de son article — le modèle de libellé à
l’œuvre. Le tableau regroupe maintenant trois tickets sur les quatre colonnes.
Ces documents sont là pour l’essai : la publication les abandonne, sauf si
vous cochez « Importer les documents existants » à l’étape 7.

## 6. Vérifiez le brouillon

Cliquez sur « Quitter l’aperçu » pour revenir au Builder, puis ouvrez l’onglet
« Vérification ». Le rapport passe en revue chaque doctype du brouillon et
regroupe le résultat **By doctype**. Un doctype propre affiche `0 issues`. La
liste « Remarques » en dessous rassemble les valeurs par défaut
informatives — un modèle de recherche manquant, les types de vue standard.
Aucune ne demande d’action.

Une erreur revient souvent sur un domaine neuf : un doctype sans modèle de
libellé ni modèle de recherche. Le rapport dit « No display_name and no search
template: the cross-doctype search endpoint skips the doctype… ». S’il en
nomme un des vôtres, ouvrez l’onglet « Général » de ce doctype, réglez le
« Modèle de libellé », enregistrez, puis cliquez sur « Actualiser » dans
l’onglet « Vérification ». Quand il ne reste rien, la boîte de publication
confirme : « Aucun problème détecté. Prêt à publier. »

## 7. Publiez

Cliquez sur « Publier » dans la barre supérieure. La boîte de dialogue
« Publier le domaine brouillon » préremplit le « Nom du domaine cible » avec
`equipment`.

![The Publish draft domain dialog over the Check tab: the target domain name prefilled with equipment, the Import existing documents box unticked, and Cancel and Publish buttons.](/screens/build/first-domain-7.png)

Laissez la case « Importer les documents existants » décochée — les documents
d’essai restent derrière et le brouillon disparaît. Cliquez sur « Publier ».

Facet copie les définitions de doctypes, les modèles de document et vos vues
enregistrées dans un domaine réel neuf nommé `equipment`, puis supprime le
brouillon. Le rapport nomme le domaine publié ; la page d’accueil du Builder
ne montre plus de brouillons.

## 8. Voyez-le dans l’espace de travail

Ouvrez l’espace de travail et choisissez « Equipment » dans le sélecteur de
domaine. Les trois doctypes sont là. Ouvrez **MaintenanceTicket** : l’onglet
« Board » créé dans l’Aperçu a suivi, avec ses quatre colonnes — vides, car
les tickets d’essai sont restés derrière.

Sur l’exemple Brightwater chargé, le tableau travaille. Une colonne par état,
des cartes qui montrent l’article et la personne assignée :

![The MaintenanceTicket board of the equipment domain on the finished Brightwater example: one lane per state — Reported, Diagnosing, Waiting for parts, Fixed — with ticket cards showing the item, the state chip, and the assignee.](/screens/build/first-domain-1.png)

Le domaine `equipment` est la base de toute l’histoire Brightwater. Le domaine
`clients` porte les entreprises, et le domaine `rentals` porte leurs
réservations — chaque ligne de réservation référence un de vos articles. Les
surfaces sur lesquelles votre équipe travaille chaque jour ressemblent à
ceci :

![The Booking list of the finished Brightwater example: the All bookings table view with search, filters, Export and Import, beside a Calendar view tab.](/screens/build/first-domain-2.png)

![A Booking document of the finished example: its fields, the Lines children as chips, and the comments pane.](/screens/build/first-domain-3.png)

Vous avez construit et livré un domaine. Le domaine réel `equipment` porte
trois doctypes et des champs typés : une référence, un enum, une devise, une
contrainte d’unicité. Un tableau kanban regroupe les tickets par état. Les
modèles de libellé donnent à chaque document son nom. Pour changer le modèle
plus tard, ouvrez le Builder et utilisez « Modifier un existant » — Facet
crée le brouillon du domaine réel pour vous.

## Ce que vous avez appris

- Un brouillon est une zone de travail privée ; la publication copie la
  structure et supprime le brouillon — lisez-en plus dans
  [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/).
- Chaque type de champ et ses réglages —
  [Types de champs](/fr/build/model/data/field-types/).
- Le rapport de vérification, et ce qu’il implique pour une publication —
  [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/).
- Tableaux, kanbans et calendriers comme vues enregistrées —
  [Vues de collection](/fr/build/model/views/lists-boards-calendars/).
- L’assistant peut proposer le modèle avec vous —
  [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/).
- Vous préférez les fichiers et les diffs ? Le même domaine peut vivre sous
  forme d’un dossier de fichiers —
  [Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/).

## Dépannage

### L’enregistrement refuse un nom de champ

L’erreur « Ce nom de champ est réservé et ne peut pas être utilisé » nomme une
clé que Facet utilise en interne (`state`, `id`, `version`, `links`, et les
horodatages système). Choisissez une autre clé et gardez le nom visible dans
le « Titre » — c’est ce que fait l’exemple avec `status` / `State`.

### La liste « Regrouper par » n’a pas de champ

Le sélecteur n’offre que les champs enum et booléen qui portent un filtre
d’égalité. Ouvrez le champ dans le Builder et vérifiez ses « Capacités de
filtrage ».

### La publication refuse le nom cible

Le nom doit être composé de lettres minuscules, de chiffres et de tirets, et
commencer par une lettre. Un nom qui commence par `_` est un nom de brouillon.
Corrigez l’« ID du domaine » dans l’onglet Vue d’ensemble du brouillon, puis
publiez de nouveau.

### La publication dit que le nom du domaine est déjà pris

Un domaine réel porte déjà ce nom — des données de démonstration, ou une
exécution antérieure de ce tutoriel. Facet refuse la première publication sur
un nom existant, et la boîte de dialogue propose ensuite « Publier par-dessus
{name} ». Confirmez seulement si vous voulez remplacer la structure de ce
domaine : chaque doctype que vous avez modifié doit incrémenter sa version de
schéma d’une unité et porter une migration — voir
[Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/).
Pour garder le domaine existant, tapez un autre nom dans le champ cible de la
boîte de dialogue et publiez de nouveau.

### Ma modification n’est pas apparue aussitôt

Le cache des définitions se met à jour une seconde ou deux après un
enregistrement. Attendez un instant et testez de nouveau.

### Une modification de champ ne s’est pas appliquée

Les modifications de champ restent locales jusqu’au bouton « Enregistrer » de
l’en-tête. Le message flash « Enregistré » est la confirmation — revérifiez le
champ et enregistrez de nouveau.

## Voir aussi

- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/)
  — le cycle de vie complet du brouillon, les co-éditeurs, et la publication
  sur un domaine réel.
- [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/) —
  chaque catégorie que le rapport peut nommer.
- [Types de champs](/fr/build/model/data/field-types/) — le système de types
  en entier.
- [Vues de collection](/fr/build/model/views/lists-boards-calendars/) — les
  vues tableau, kanban et calendrier au-delà de l’écran de démarrage.
- [Comment fonctionnent les brouillons](/fr/build/model/in-app/how-drafts-work/)
- [Types de champs](/fr/reference/field-types/)

## Pour aller plus loin

Votre domaine est publié. Dans
[Livrez votre première app](/fr/build/first-hour/first-app/), vous construisez
l’application de sortie du matériel de Brightwater par-dessus, et l’équipe
d’entrepôt se connecte à travers Facet.
