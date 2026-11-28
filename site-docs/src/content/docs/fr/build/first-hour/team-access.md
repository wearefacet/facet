---
type: tutorial
title: Donner accès à votre équipe
description: Inviter un collègue, lui attribuer le rôle warehouse, et voir ce que masquent l’étiquette finance et un périmètre de lignes.
audience: [admin]
features: [IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11]
sidebar:
  order: 5
verified_at: eee55a2
---

Un nouvel employé rejoint l’entrepôt de Brightwater : Pat Mardell. Il a
besoin du domaine `equipment` — articles, catégories, tickets de maintenance —
et il ne doit jamais voir ce que le matériel a coûté. Tom, le commercial,
travaille déjà dans Facet : il ne voit que les clients qu’il gère, jamais les
autres. Ce tutoriel invite Pat, lui confie le rôle `warehouse`, et se termine
par un regard sur les données avec les yeux de l’équipe.

Deux règles font le travail, toutes deux réglées une fois et appliquées
partout — listes, espace de travail, API, assistant :

- Un **rôle** rassemble des permissions : les doctypes qu’une personne peut
  lire et modifier. Pat reçoit le rôle `warehouse`.
- Une **étiquette de champ** marque un champ sensible. Un rôle qui ne porte
  pas l’étiquette ne peut pas voir le champ. `purchase_price` porte
  l’étiquette `finance` ; seul `manager` la porte.
- Un **périmètre de lignes** filtre les lignes qu’un rôle atteint. Le rôle
  `sales` de Tom ne lit les entreprises qu’à travers le périmètre
  `my_clients` — les entreprises où il est responsable de compte.

**Vous mettez en place :** un compte avec le rôle `warehouse`, vérifié contre
l’étiquette de champ ; la liste à périmètre de Tom, vérifiée contre le
périmètre de lignes.
**Durée :** environ 15 minutes.
**Prérequis :**

- [Le tutoriel 1](/fr/build/first-hour/run-facet/) — une instance en marche
  avec un compte administrateur (`admin@example.tld` / `admin` sur une
  instance `setup-dev`). L’exemple Brightwater est chargé
  ([le tutoriel 2](/fr/build/first-hour/first-domain/) le fait ; le `load.sh`
  de l’exemple le fait aussi).
- `curl` et `pnpx @facetapp/cli` pour l’étape API, qui lie deux clés API à
  deux rôles.

## 1. Créez le compte de Pat

Connectez-vous comme administrateur et ouvrez « Configurer → Accès →
Comptes ». Cliquez sur « Nouveau compte » et remplissez le formulaire —
« E-mail » et « Nom d’affichage » sont les seuls champs requis :

- **E-mail** : `pat@brightwater.example`
- **Nom d’affichage** : `Pat Mardell`

![The New Account form with the email and display name filled in. Status starts at Active and the organizational unit at /.](/screens/build/team-access-3.png)

Cliquez sur « Créer ». La page du compte s’ouvre avec le statut *En attente* —
le compte existe, mais ne porte pas encore d’identifiant.

Trouvez le panneau « Identifiants » et cliquez sur « Générer un mot de
passe ». Facet montre le mot de passe temporaire une seule fois :

![The Temporary password generated dialog: a one-time password with a Copy button, and a note that it is shown only now.](/screens/build/team-access-4.png)

:::caution
Transmettez le mot de passe à Pat par un canal sûr — un gestionnaire de mots
de passe, pas un e-mail. Il ne s’affiche qu’une fois. S’il est perdu, cliquez
sur « Régénérer le mot de passe » et remettez le nouveau. Si votre instance a
un SMTP fonctionnel, « Envoyer l’invitation » est l’alternative : Pat reçoit
alors un lien à usage unique.
:::

Pat change le mot de passe à sa première connexion — le même écran « Définir
un nouveau mot de passe » que vous avez vu au tutoriel 1.

## 2. Attribuez le rôle warehouse

Ouvrez « Configurer → Accès → Affectations » et passez en « Par compte ».
Choisissez Pat dans « Sélectionnez un compte… » — le panneau *Roles assigned
to account* démarre vide. Ouvrez le sélecteur « Ajouter un rôle à ce
compte… », choisissez « Warehouse », puis cliquez sur « Affecter un rôle » :

![The Assignments page in By account mode: the Warehouse role assigned to Pat Mardell, with the default badge.](/screens/build/team-access-5.png)

La ligne porte un badge *default* — le premier rôle d’un compte devient son
rôle par défaut. Pat se connecte comme `warehouse` sans rien choisir.

Le rôle existe déjà dans l’exemple Brightwater (le tutoriel 2 ou `load.sh` l’a
créé). Ses permissions :

| Sur | Actions |
|---|---|
| `equipment` (tous les doctypes) | read, create, update, delete |
| `rentals.Booking`, `rentals.BookingLine` | read |
| `clients.Company`, `clients.Contact` | read |
| `core.Comment`, `core.Attachment` | read, create, update, delete |

Et une absence qui porte le tutoriel : `visible_tags` liste `default` mais pas
`finance`.

## 3. Voyez l’étiquette de champ agir

Pat ouvre un article — par exemple « Main tent 10x15 » — et la page montre
Name, Status, Category, Serial number :

![An item page as the warehouse user: name, status, category and serial number, with no purchase price.](/screens/build/team-access-2.png)

Aucun prix d’achat sur la page. Le champ n’existe pas pour ce rôle — il n’est
pas masqué par un vide, il est absent.

La même requête depuis l’API montre le même filtre. Chaque appel API présente
son propre identifiant, et la CLI en délivre un lié à un rôle que vous
portez. Gardez la clé admin de `setup-dev` sous un nom qui lui est propre,
puis liez une clé `warehouse` pour Pat — la CLI ne demande rien à Nadia, car
l’identifiant est lié à un rôle, pas à une personne :

```sh
cd /path/to/your/setup-dev/folder
AP_ADMIN_KEY=$(pnpx @facetapp/cli apikey)
PAT_KEY=$(pnpx @facetapp/cli connect --role warehouse >/dev/null && pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

`connect` connecte l’administrateur dans votre navigateur — choisissez le rôle
admin sur l’écran de consentement — et stocke une clé liée à
`iam.Roles.warehouse`. Une requête par bearer ne porte pas de cookie, donc
elle n’a pas besoin d’en-tête `X-Requested-With`. Comme Pat :

```sh
curl -skg -H "Authorization: Bearer $PAT_KEY" \
  "$HOST/Api/equipment/Item/EQ-2026-0001"
```

```json
{"data":{"name":"Main tent 10x15","status":"out","category":"equipment.Category.…","serial_number":"TN-10015-A"}}
```

Comme Nadia (le rôle `manager`, qui porte l’étiquette `finance`) — liez une
clé `manager` de la même façon :

```sh
NADIA_KEY=$(pnpx @facetapp/cli connect --role manager >/dev/null && pnpx @facetapp/cli apikey)

curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  "$HOST/Api/equipment/Item/EQ-2026-0001"
```

```json
{"data":{"name":"Main tent 10x15","status":"out","category":"equipment.Category.…","serial_number":"TN-10015-A","purchase_price":{"value":"4800.00","currency":"EUR"}}}
```

Un champ, deux réponses. La vérification s’exécute sur chaque chemin de
lecture — liste, lecture unitaire, recherche, export — si bien qu’un rôle qui
n’a pas l’étiquette ne peut atteindre la valeur nulle part.

## 4. Voyez le périmètre de lignes agir

Tom se connecte et ouvre « Clients → Company ». La liste montre cinq lignes :

![Tom's clients list shows exactly five companies, the ones he manages.](/screens/build/team-access-1.png)

Les dix entreprises de Brightwater sont dans la base ; Tom n’atteint que les
cinq où il est responsable de compte. La règle vit sur son rôle `sales` : la
permission de lecture sur `clients.Company` porte le périmètre `my_clients`,
que l’exemple définit sur le doctype Company comme « les entreprises dont le
responsable de compte est moi » (`account_manager = $self`).

Une ouverture directe de l’URL d’une autre entreprise répond *not found* —
Facet ne confirme pas que la ligne existe.

## 5. Vérifiez la trace

Ouvrez « Configurer → Journal d’audit » et cherchez les entrées du jour : le
compte de Pat créé, le rôle Warehouse attribué, sa première connexion et son
changement de mot de passe. Chaque décision d’accès de ce tutoriel a laissé
une trace — voilà tout l’intérêt de faire le travail d’accès dans Facet
plutôt que dans une feuille de calcul de qui-peut-quoi.

## Ce que vous avez appris

- Un rôle est un ensemble de permissions ; un compte en porte au moins un, et
  le premier devient le défaut.
- Une étiquette de champ cache un champ à tout rôle qui ne la porte pas —
  dans l’interface comme dans l’API.
- Un périmètre de lignes limite les lignes qu’une permission atteint ; une
  ouverture directe d’une ligne hors du périmètre répond not found.
- Le journal d’audit enregistre les changements de comptes et de rôles que
  vous avez faits.

## Voir aussi

- [Rôles et permissions](/fr/admin/people/roles-and-permissions/) —
  le modèle de permissions complet.
- [Masquer un champ à certains rôles](/fr/admin/people/hidden-fields/) — les
  étiquettes de champ en profondeur, y compris la règle du refus par défaut.
- [Montrer à chaque rôle seulement ses propres lignes](/fr/admin/people/row-scopes/) —
  la grammaire des périmètres : `$self`, ensembles de contexte, opérateurs.
- [Attribuer des rôles](/fr/admin/people/assign-roles/) — les comptes
  multi-rôles et le choix du rôle actif.
- [Personnes et accès](/fr/admin/people/)
- [Syntaxe des lignes de permission](/fr/reference/permission-syntax/)

## Pour aller plus loin

Votre équipe travaille dans Facet et vos données sont gouvernées. Dans
[Connecter un agent IA](/fr/build/first-hour/connect-an-agent/), vous attachez
un client MCP aux mêmes rôles, si bien qu’un assistant répond aux questions
sous les mêmes règles — et laisse la même trace d’audit.
