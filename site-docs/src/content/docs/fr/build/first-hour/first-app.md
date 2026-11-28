---
type: tutorial
title: Livrez votre première app
description: Enregistrez l’app Brightwater Check-out, construisez-la avec un agent de code, déployez-la, puis connectez-vous via Facet.
audience: [developer]
features: [APP-01, APP-02, APP-05, APP-06, APP-09, APP-10]
sidebar:
  order: 4
verified_at: c2d5808
---

L’entrepôt Brightwater suit son stock dans un tableur. Vous allez le remplacer
par une petite application web : les réservations confirmées, avec un bouton
qui marque chaque article sorti, puis rentré. Facet enregistre l’app, borne ce
qu’elle a le droit de faire, l’héberge et connecte ses utilisateurs — le
tableur n’offre rien de tout cela.

Le tutoriel compte trois parties :

1. **Enregistrer l’app sur Facet** — avec l’assistant du tableau de bord, ou
   en deux commandes.
2. **La construire avec votre agent de code** — un prompt ; l’agent écrit le
   code.
3. **Essayer et livrer** — connectez-vous, puis déployez avec la CLI.

**Durée :** environ 30 minutes.
**Il vous faut :**

- [Tutoriel 1](/fr/build/first-hour/run-facet/) — une instance en marche, avec
  l’exemple Brightwater chargé ([le tutoriel
  2](/fr/build/first-hour/first-domain/) le fait, ou le `load.sh` de
  l’exemple).
- Node.js 20+ avec pnpm (`curl` et `jq` servent uniquement à l’enregistrement
  scripté).
- Un outil d’agent de code — Claude Code, Codex ou OpenCode. Tout agent qui
  lit des fichiers et exécute des commandes convient.

:::note
L’agent de code dont il est question ici est le vôtre — Claude Code, Codex,
OpenCode ou un outil semblable. L’assistant intégré à Facet est un autre
outil : il modélise des domaines dans le Builder et répond dans l’espace de
travail. Son utilisation exige qu’un administrateur connecte un modèle de
langage — voir
[Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/).
:::

## Partie 1 — Enregistrer l’app sur Facet

Sur Facet, une app est un document. Ce document établit qui est l’app, vers
quelles adresses les connexions peuvent revenir, et quelles données elle a le
droit de toucher — ses **octrois**. L’app de sortie de matériel lit les
réservations et leurs lignes, et lit et met à jour les articles de matériel.

Deux façons de l’enregistrer — les deux écrivent le même document, choisissez
la vôtre :

- **[L’assistant](#1-enregistrer-via-lassistant)** — quatre écrans dans le
  tableau de bord. Le chemin le plus confortable.
- **[Le script](#2-ou-scripter-lenregistrement)** — deux commandes de
  terminal autour d’un fichier `facet-app.json`. Le chemin répétable ;
  réutilisez-le pour la prochaine app.

### 1. Enregistrer via l’assistant

Ouvrez **Configurer → Apps** et cliquez sur **Nouvelle application**.
L’assistant traverse quatre étapes : **Création**, **Autorisations**,
**Récapitulatif**, **Identifiants**.

**Création.** Remplissez les champs avec les adresses de l’app de sortie de
matériel :

- **Display name** — `Brightwater Check-out`
- **Slug** — cliquez sur **Modifier** à côté de l’adresse dérivée et
  définissez `brw-checkout`. La suite du tutoriel l’utilise.
- **Propriétaire** — votre compte par défaut ; laissez tel quel.
- **Origines autorisées** — `http://localhost:5173`, puis
  `https://checkout.apps.localhost:3443`
- **URI de redirection** — `http://localhost:5173/auth/callback`, puis
  `https://checkout.apps.localhost:3443/auth/callback`

Chaque entrée de liste : saisissez l’adresse, puis appuyez sur Entrée. Chaque
adresse figure deux fois — le serveur de dev sur votre machine, et le build
hébergé que vous déployez en partie 3.

![The Set it up step of the app wizard: display name Brightwater Check-out, slug brw-checkout, two allowed origins and two redirect URIs.](/screens/build/first-app-wizard-setup.png)

**Autorisations.** Un niveau d’accès par doctype, groupé par domaine. Ouvrez
les onglets de domaine **Rentals** et **Equipment**, puis définissez :

| Doctype | Niveau | Le rôle doit posséder dès la configuration |
| --- | --- | --- |
| `rentals.Booking` | **Lecture** | Consulter → requis |
| `rentals.BookingLine` — imbriqué sous Booking | **Lecture** | Consulter → requis |
| `equipment.Item` | **Écriture** | Consulter → requis, Créer et modifier → requis |

Laissez **Aucun** pour chaque autre doctype. Chaque ligne de la colonne **Le
rôle doit posséder dès la configuration** liste les actions du niveau sous
forme de pastilles avec un interrupteur ; basculez un interrupteur pour
marquer l’action `required`. Une action requise demande une seule chose à
chaque rôle qui se connecte : porter cette action. L’écran de consentement ne
liste alors que les rôles qui la portent.

![The Permissions step: Booking and BookingLine on Read, Item on Write, with each action's required toggle turned on.](/screens/build/first-app-wizard-permissions.png)

**Récapitulatif.** La liste de contrôle confirme chaque élément requis, et
**Ce que les utilisateurs verront** montre un aperçu de l’écran de
consentement. Cliquez sur **Publier** :

![The Review step: the required checklist with three ticks, and the consent preview — Brightwater Check-out wants to read bookings, bookinglines and items, and create and edit items.](/screens/build/first-app-wizard-review.png)

La publication passe le statut à `active` — les connexions fonctionnent à
partir de là.

**Identifiants.** Le dernier écran montre le `client_id` écrit par Facet,
l’adresse de connexion et le document de découverte. Une app publique ne porte
aucun secret : la connexion s’appuie sur Proof Key for Code Exchange (PKCE) à
la place.

![The Credentials screen: the client id, the sign-in address, the discovery document, and the "No client secret" panel naming PKCE and DPoP.](/screens/build/first-app-wizard-credentials.png)

### 2. Ou scripter l’enregistrement

Vous préférez le terminal ? Créez le dossier du projet et enregistrez-y la
description de l’app sous le nom `facet-app.json` :

```sh
mkdir brightwater-checkout && cd brightwater-checkout
```

```json title="facet-app.json"
{
  "slug": "brw-checkout",
  "name": "Brightwater Check-out",
  "client_type": "public",
  "host": "checkout.apps.localhost",
  "redirect_uris": [
    "http://localhost:5173/auth/callback",
    "https://checkout.apps.localhost:3443/auth/callback"
  ],
  "allowed_origins": [
    "http://localhost:5173",
    "https://checkout.apps.localhost:3443"
  ],
  "grants": [
    { "target": "rentals.Booking", "actions": [{ "name": "read", "required": true }] },
    { "target": "rentals.BookingLine", "actions": [{ "name": "read", "required": true }] },
    { "target": "equipment.Item", "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }] }
  ]
}
```

Chaque adresse figure deux fois : une pour le serveur de dev sur votre
machine, une pour le build hébergé sur `checkout.apps.localhost`. Le `host`
est un nom d’hôte brut — sans schéma, sans port. `public` signifie que l’app
tourne dans le navigateur et ne porte aucun secret. Enregistrez et activez
ensuite — la CLI fournit l’adresse de l’instance et la clé d’administration
qu’elle a stockée pour Ravi au moment de `setup-dev` :

```sh
HOST=$(pnpx @facetapp/cli host)
FACET_KEY=$(pnpx @facetapp/cli apikey)

# Enregistrer l’app ; conserver son identifiant.
APP_ID=$(curl -sk -X POST "$HOST/Api/app/App" \
  -H "Authorization: Bearer $FACET_KEY" \
  -H "Content-Type: application/json" \
  -d @facet-app.json | jq -r .meta.id)
echo "$APP_ID"

# Une nouvelle app est un brouillon. Activer les connexions.
curl -sk -X PATCH "$HOST/Api/app/App/$APP_ID" \
  -H "Authorization: Bearer $FACET_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}' | jq '.data | {slug, status}'
```

```text
06H1FQF7NGDJJKSNHXPYT6627M
{"slug": "brw-checkout", "status": "active"}
```

Vos identifiants diffèrent — chaque instance émet les siens.

Ce sont tous les appels API du tutoriel. Le rôle Warehouse créé par
l’initialisation atteint déjà l’app : l’écran de consentement compte aussi les
lignes à périmètre de domaine d’un rôle, et la ligne
`{"on": "equipment", "action": "*"}` de ce rôle couvre l’octroi sur
`equipment.Item`. Aucun changement de rôle n’est nécessaire. Vous préférez
cliquer ? L’assistant du tableau de bord fait la même chose — voir
[Enregistrer une app](/fr/build/apps/connect/register/).

## Partie 2 — La construire avec votre agent de code

### 3. Préparer le projet

Créez le dossier du projet, installez le SDK et les outils de build, puis
écrivez la configuration de déploiement :

```sh
mkdir brightwater-checkout && cd brightwater-checkout
pnpm init
pnpm add @facetapp/sdk
pnpm add -D typescript vite
HOST=$(pnpx @facetapp/cli host)
pnpx @facetapp/cli init --app brw-checkout --build dist --server "$HOST"
```

`init` écrit `facet.config.json`, puis recherche l’app sur l’instance. Sans
session CLI enregistrée, il s’arrête après la configuration :

```text
Wrote facet.config.json for app "brw-checkout".
No stored session for https://facet.localhost:3443. Run "pnpx @facetapp/cli login" to sign in.
```

Vous connecterez la CLI au moment du déploiement, en partie 3.

### 4. Confier la construction à votre agent

Ouvrez votre outil d’agent de code dans le dossier du projet et collez ce
prompt :

```text
Build a small single-page app in this folder, in TypeScript with Vite.

Goal: the Brightwater check-out board. The app signs its users in through
Facet and shows the confirmed bookings with their items. Each item row
carries a button that flips the item status between "out" and "available".

Facts you must not invent — fetch them first:
- Docs index: https://docs.facet.example/llms.txt — then read these pages as
  raw markdown by adding .md to the path:
  /build/apps/quickstart.md        (registration and the sign-in sequence)
  /build/apps/connect/user-login.md (the browser sign-in flow)
  /build/apps/data/sdk.md          (the TypeScript SDK)
  /build/apps/data/rest-api.md     (the API grammar)
- Copy the complete code blocks from those pages. Do not invent endpoints,
  parameters, or error bodies.

Project facts:
- Facet instance: https://facet.localhost:3443
- App slug: brw-checkout (already registered, client_type public)
- Sign-in: OAuth authorization code + PKCE through @facetapp/sdk's
  oauthBrowser({ slug, redirectUri }) — redirect path /auth/callback
- Data:
  rentals.Booking: client_name (copied from the client), dates {start, end},
    status (draft | confirmed | returned), total
  rentals.BookingLine (child of Booking): item (reference to equipment.Item),
    quantity, price
  equipment.Item: name, status (available | out | in_repair), serial_number

Build:
- index.html, src/main.ts, src/style.css, tsconfig.json — Vite vanilla
  TypeScript; add "dev" and "build" scripts (vite, and tsc && vite build)
  to package.json
- On the /auth/callback path, finish the sign-in and return to /
- Signed out: one "Sign in with Facet" button
- Signed in: one card per confirmed booking (client name, dates), with a
  table of its lines (item name, serial, quantity, status) and a button that
  updates the item status to "out" or "available", then re-renders
- An item whose status is "in_repair" shows no button
- Surface API errors as text; a 403 means the app's grant does not reach

When done, run `pnpm build` and make it pass with no type errors.
```

La sortie d’un agent varie ; contrôlez le résultat plutôt que la formulation :

- `pnpm build` passe sans erreur de type.
- `src/main.ts` crée le client avec
  `oauthBrowser({ slug: 'brw-checkout' … })` et sans secret.
- Le bouton de connexion appelle `auth.signIn()` ; le chemin de callback
  appelle `auth.handleCallback(location.href)`.
- Les données passent par `facet.domain('rentals')` et
  `facet.domain('equipment')` — aucune autre route.

Si quelque chose cloche, ou si vous préférez vous passer de l’agent, copiez
le source achevé depuis
[`site-docs/examples/brightwater/checkout-app/`](https://github.com/wearefacet/facet/tree/main/site-docs/examples/brightwater/checkout-app)
— la suite du tutoriel fonctionne dans les deux cas.

## Partie 3 — Essayer et livrer

### 5. Se connecter comme Lucía

Lucía Ferrer dirige l’entrepôt ; l’app est pour elle. Démarrez le serveur de
dev :

```sh
pnpm dev
```

Ouvrez `http://localhost:5173` et cliquez sur « Sign in with Facet ».
Connectez-vous comme `lucia@brightwater.example`. Facet affiche alors l’écran
de consentement : il nomme l’app, liste le rôle avec lequel Lucía peut
l’utiliser, et ce que l’app a le droit de faire sous ce rôle :

![The Facet consent screen for Brightwater Check-out: the Warehouse role with the reach the app keeps — Booking and BookingLine read, Item read, create, update.](/screens/build/first-app-1.png)

Elle choisit **Warehouse** et clique sur **Autoriser**. Le navigateur revient
à l’app, et le tableau s’affiche :

![The check-out board: one card per confirmed booking, with the items, their status and an out/back button.](/screens/build/first-app-2.png)

Marquez un article sorti, puis rentré — le statut change aussi sur Facet.

**Ce que l’app peut atteindre.** L’app agit avec l’intersection de ses octrois
et du rôle de Lucía — jamais plus que ce que l’un ou l’autre permet. Son rôle
Warehouse peut aussi lire les clients, mais les octrois de l’app ne nomment
pas `clients.Company` : l’app ne peut donc pas les lire, et chaque appel de ce
type répond `403`. Le pourquoi, et ce que voit un administrateur, sont dans
[Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/).

:::tip[L’écran de consentement ne liste aucun rôle ?]
Facet ne propose que les rôles qui couvrent chaque octroi requis par l’app,
doctype par doctype. Voir
[Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/).
Pour observer chaque appel de connexion avec `curl`, voir
[Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/).
:::

### 6. Déployer sur Facet

L’app tourne sur votre machine ; laissez maintenant Facet l’héberger.
L’enregistrement porte déjà la redirection hébergée et son origine CORS.
L’assistant ne collecte pas d’hôte : définissez-le dans l’onglet
**Paramètres** de l’app, sous **Hébergement** — un nom d’hôte brut, sans
schéma, sans port.

![The Settings tab of the app: the Serving section with the host checkout.apps.localhost and its Save button.](/screens/build/first-app-wizard-host.png)

Construisez, connectez la CLI, puis déployez :

```sh
pnpm build
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

`login` ouvre un écran de consentement dans votre navigateur, pour la CLI
elle-même — connectez-vous comme administrateur. `deploy` empaquette `dist/`,
le téléverse et l’active :

```text
Deploying "dist" to https://facet.localhost:3443 (target of app "brw-checkout")…
Packed 3 files.
Deployed revision 1 (3 files stored).
Active at https://checkout.apps.localhost:3443
```

(La capture ci-dessus a été prise sur une copie jetable de l’app, enregistrée
comme `brw-checkout-t3` ; votre exécution porte le nom `brw-checkout` et votre
hôte.) Ouvrez `https://checkout.apps.localhost:3443` et connectez-vous à
nouveau — le tableau y fonctionne aussi. Chromium résout `*.apps.localhost`
tout seul ; pour Firefox, ajoutez `127.0.0.1 checkout.apps.localhost` à votre
fichier hosts.

Quiconque atteint l’adresse obtient la page ; les données restent derrière la
connexion. Révisions, retour arrière et domaines personnalisés sont dans
[Déployer votre app sur Facet](/fr/build/apps/host/deploy/).

## Ce que vous avez appris

- Une app est un document : l’assistant l’écrit en quatre étapes, l’API en
  deux commandes. La publication passe le statut à `active` — les connexions
  commencent.
- L’écran de consentement ne liste que les rôles qui couvrent chaque action
  d’octroi requise. L’intersection compte aussi les lignes à périmètre de
  domaine d’un rôle — le rôle Warehouse créé par l’initialisation qualifie
  sans ligne supplémentaire.
- Un agent de code peut construire une app Facet à partir de la documentation
  seule, à condition de lui indiquer les pages et de lui donner les faits du
  projet.
- La portée de l’app est l’intersection de ses octrois et du rôle de
  l’utilisateur — un appel hors des octrois répond `403`, quel que soit ce
  que le rôle permet.
- La CLI déploie un build statique comme une révision, et Facet le sert sur
  l’hôte propre de l’app sans redémarrage.

## Voir aussi

- [Enregistrer une app](/fr/build/apps/connect/register/) — chaque champ
  d’enregistrement, et l’assistant du tableau de bord.
- [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/) —
  les rôles que l’écran de consentement propose, et pourquoi.
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/)
  — le flux de connexion complet, étape par étape avec `curl`, refresh et
  DPoP inclus.
- [Origines autorisées et CORS](/fr/build/apps/connect/cors/) — pourquoi
  chaque adresse avait besoin d’une entrée.
- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — la grammaire derrière
  chaque appel de l’app.
- [Intégrer l’assistant à votre app](/fr/build/apps/host/embed-assistant/) —
  l’instance doit d’abord avoir un modèle connecté.
- [CLI des apps Facet](/fr/reference/cli-npm/)

## Pour aller plus loin

L’app fonctionne, et ses utilisateurs ne voient que ce que leurs rôles
permettent. Dans
[Donner accès à votre équipe](/fr/build/first-hour/team-access/), vous
invitez un collègue et observez les règles de rôle masquer ce qu’il ne doit
pas voir.
