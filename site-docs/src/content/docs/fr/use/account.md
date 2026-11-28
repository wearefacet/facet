---
type: how-to
title: Vos réglages et clés API
description: Réglez votre fuseau horaire et votre langue, connectez un agent IA, gérez les clés API qui agissent en votre nom, et déconnectez des appareils.
audience: [user]
features: [FE-17, PLT-17, IAM-09, IAM-11]
sidebar:
  order: 6
verified_at: eee55a2
---

Les dates de vos réservations s’affichent dans le mauvais fuseau horaire, ou
un outil de reporting a besoin de son propre accès à Facet. Les pages de
réglages corrigent le premier cas et permettent le second. Elles rassemblent
vos préférences personnelles, les clés qui laissent une machine agir en votre
nom, et la liste des appareils connectés sous votre identité. Tout ce qui se
trouve ici ne concerne que votre compte — chaque personne garde ses propres
réglages.

## Avant de commencer

- [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) — il vous faut
  une session connectée pour accéder aux réglages.

![The settings page: chapters for General, Notifications, MCP endpoints and Active sessions on the left.](/screens/use/account-1.png)

## Ouvrir vos réglages

Sélectionnez votre nom en bas de la barre latérale. Le menu s’ouvre :

- **Mes paramètres** — la page que cet article parcourt.
- **Clés API** — pour l’accès machine, traité plus bas.
- **Webhooks** — envoyer un message à un autre système quand des
  enregistrements changent.
- **Changer de rôle** — apparaît quand vous détenez deux rôles ou plus.
- **Déconnexion**.

Sur la page de réglages, les chapitres se trouvent à gauche : **Général**,
**Notifications**, **Points de terminaison MCP** et **Sessions actives**. Les
comptes qui détiennent le rôle administrateur intégré voient aussi **Visite
de bienvenue**. Chaque changement s’enregistre aussitôt — le champ affiche
brièvement **Enregistré**.

Votre administrateur gère votre nom et votre adresse e-mail — ils ne
figurent pas sur cette page. Il en va de même pour votre mot de passe : vous
ne le changez que lorsqu’un administrateur vous délivre un mot de passe
temporaire et que Facet vous le demande à la connexion. Voir
[Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/).

## Régler votre fuseau horaire

Dans **Général**, ouvrez **Fuseau horaire** et choisissez une option :

- **Automatique** — Facet utilise le fuseau de l’appareil depuis lequel vous
  vous connectez.
- **Valeur par défaut du serveur** — Facet utilise la valeur par défaut de
  cette installation Facet.
- Une zone nommée de la liste, par exemple `Europe/Paris`.

La ligne **Heure actuelle**, juste en dessous, prévisualise votre choix.
Facet affiche les dates et les heures dans toute l’application dans ce
fuseau. Le choix ne s’applique qu’à vous — un collègue dans un autre bureau
voit le sien.

## Régler votre langue

Dans **Général**, ouvrez **Langue** et choisissez **English**, **Français**
ou **Valeur par défaut du serveur**. La page se recharge dans la nouvelle
langue.

## Copier un point de terminaison MCP

Dans **Points de terminaison MCP**, Facet liste une adresse pour chaque rôle
que vous détenez. Un agent IA — un programme d’assistance tel que Claude
Desktop — se connecte à Facet par cette adresse. Il travaille ensuite comme
ce rôle, sous les mêmes règles que vous. À la première connexion, l’agent se
connecte par une fenêtre de navigateur. Sélectionnez **Copier** pour copier
l’adresse. Quand aucun de vos rôles n’expose de point de terminaison, la
page l’indique.

## Vos clés API

Une clé API laisse un programme — un script, un outil de reporting, une
intégration — appeler l’interface de Facet en votre nom, sous un rôle que
vous choisissez. Le programme peut alors tout faire de ce que ce rôle
permet, et rien de plus. Tel est l’intérêt et le risque : quiconque détient
la clé agit comme vous. Traitez une clé comme un mot de passe. Collez-la
directement là où le programme en a besoin, ne l’envoyez jamais par
messagerie ni par e-mail, et révoquez-la une fois le travail terminé. Votre
administrateur définit ce que les rôles peuvent faire ; voir
[Les rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

![The API keys page: the list of keys with name, role, last used and status.](/screens/use/account-2.png)

**Créer une clé**

1. Ouvrez le menu du compte et sélectionnez **Clés API**.
2. Sélectionnez **Créer une clé**.
3. Dans **Nom**, tapez un libellé. Vous seul le voyez — jusqu’à 100
   caractères.
4. Dans **Rôle**, choisissez l’un de vos rôles attribués. La clé ne peut
   faire que ce que ce rôle permet.
5. Dans **Expire le**, choisissez une date, ou laissez vide pour une clé qui
   n’expire jamais.
6. Sélectionnez **Créer une clé**. Facet affiche la clé complète une seule
   fois — sélectionnez **Copier** et conservez-la en lieu sûr.

:::caution
La clé complète s’affiche une seule fois et ne peut pas être récupérée
ensuite. Si vous la perdez, créez une nouvelle clé.
:::

**Révoquer une clé**

1. Dans la liste des clés, sélectionnez **Révoquer** sur la ligne de la clé.
2. Confirmez avec **Révoquer la clé**. Les programmes qui utilisent la clé
   cessent de fonctionner aussitôt, et ceci est irréversible.

La ligne reste dans la liste avec le badge **Révoquée**. Chaque ligne montre
le nom de la clé, son préfixe court, le rôle, **Dernière utilisation**,
**Expire le**, et un statut : **Active**, **Expirée** ou **Révoquée**. Une
clé sans expiration affiche **Jamais**.

Une clé cesse aussi de fonctionner quand elle expire, quand vous perdez le
rôle sous lequel elle agit, ou quand votre compte est désactivé. La clé
complète commence toujours par `fct_` — les pages détail expliquent comment
un programme la transmet :

- [Clés API (admin)](/fr/admin/apps-access/api-keys/) — le fonctionnement des
  clés, pour la personne qui gère les accès.
- [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/) —
  la voie de l’identité machine qu’empruntent les développeurs.

## Déconnecter un appareil

Dans **Sessions actives**, Facet liste chaque appareil ou application
connecté sous votre identité. Chaque ligne montre l’appareil ou
l’application, l’adresse réseau, le rôle sous lequel la session s’exécute,
et les heures **Créé** et **Dernière utilisation**. Une ligne sans détails
d’appareil affiche **Appareil inconnu**.

**Déconnecter un appareil.** Sélectionnez **Révoquer** sur sa ligne et
confirmez avec **Révoquer la session**. L’appareil se déconnecte à son
prochain rafraîchissement.

**Déconnecter tous les autres appareils.** Sélectionnez **Révoquer les
autres sessions** et confirmez avec **Révoquer les autres**. Votre session
actuelle reste connectée, et Facet indique combien de sessions il a
révoquées.

Facet ne coupe pas un appareil en pleine action : une connexion déjà ouverte
continue de fonctionner quelques minutes, puis l’appareil doit se
reconnecter.

## Dépannage

### L’entrée Clés API manque dans le menu du compte

Votre rôle actif ne permet pas l’accès API. Ouvrez le menu du compte et
essayez **Changer de rôle**, ou demandez à votre administrateur d’autoriser
l’accès API sur l’un de vos rôles.

### Vous ne pouvez pas créer de clé

Vérifiez le formulaire. Le rôle doit être l’un de vos rôles attribués, et il
doit permettre l’accès API. La date d’expiration doit être dans le futur.

### Une clé a cessé de fonctionner

Ouvrez **Clés API** et vérifiez le statut. Les clés **Révoquée** et
**Expirée** ne fonctionnent plus jamais — créez une nouvelle clé. Si le
statut est **Active**, demandez à votre administrateur si le rôle permet
toujours l’accès API.

### Un appareil fonctionne encore un moment après la révocation

Une connexion déjà ouverte continue de fonctionner jusqu’à sa fin — quelques
minutes par défaut. Ensuite, l’appareil doit se reconnecter.

## Voir aussi

- [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) — connexion,
  configuration du second facteur, et changement de mot de passe.
- [Notifications](/fr/use/notifications/) — ce que contrôle l’interrupteur
  des notifications dans l’application.
- [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/) — mettre un
  point de terminaison MCP au service de votre travail.
- [Les rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/) — ce
  qu’un rôle permet, pour vous et pour vos clés.
- [Sécurité et gouvernance](/fr/discover/security/)
- [Clés de réglage de compte](/fr/reference/account-settings-keys/)
