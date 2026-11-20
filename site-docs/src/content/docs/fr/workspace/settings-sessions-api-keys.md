---
title: Paramètres, sessions et clés API
description: Régler votre fuseau horaire et votre langue, relire vos sessions, et gérer les clés API des clients machine.
audience: [user]
features: [FE-17, PLT-17, IAM-09, IAM-11]
sidebar:
  order: 12
verified_at: 49d7c7e5
---

Les pages Paramètres rassemblent vos préférences personnelles, vos clés d’API
(interface de programmation), et vos sessions actives. Tout ce qui est ici
n’appartient qu’à votre compte. Les autres comptes gardent leurs propres
réglages.

## Avant de commencer

- **Un compte.** Il vous faut un compte connecté. Pour l’aide à la connexion,
  voir [Connexion, MFA et mot de passe](/fr/workspace/sign-in-mfa/).
- **Vos réglages seulement.** Votre administrateur gère les rôles et les
  données de compte. Cette page ne couvre que vos réglages personnels.

## Étapes

### 1. Ouvrez vos réglages

1. Sélectionnez votre nom de compte en bas de la barre latérale.
2. Sélectionnez « Mes paramètres ».

La page montre des chapitres à gaucheà : « Général », « Notifications »,
« Points de terminaison MCP » et « Sessions actives ». Les comptes avec le
rôle administrateur intégré voient aussi « Visite de bienvenue ». Chaque
changement s’enregistre aussitôtà ; le champ fait clignoter
« Enregistré ».

Le même menu ouvre « Clés API » (plus bas) et « Webhooks ». Il affiche
« Changer de rôle » quand vous détenez deux rôles ou plus, et « Déconnexion ».

### 2. Réglez votre fuseau horaire

Dans « Général », ouvrez « Fuseau horaire » et choisissez une option :

- « Automatique » — Facet utilise le fuseau de l’appareil d’où vous vous
  connectez.
- « Valeur par défaut du serveur » — Facet utilise la valeur par défaut de
  cette instance Facet.
- Une zone nommée de la liste, par exemple `Europe/Paris`.

La ligne « Heure actuelle » sous les sélecteurs prévisualise votre choix.
Facet affiche les dates et les heures dans toute l’application dans ce fuseau.
Votre choix ne s’applique qu’à vous.

### 3. Réglez votre langue

Dans « Général », ouvrez « Langue ». Choisissez « English », « Français » ou
« Valeur par défaut du serveur ». La page se recharge dans la nouvelle langue.

### 4. Réglez les notifications dans l’application

Dans « Notifications », utilisez l’interrupteur « Notifications dans
l’application ». Il affiche ou cache les notifications dans la cloche de la
barre supérieure. Quand vous rallumez les notifications, vous voyez celles qui
sont arrivées pendant qu’elles étaient éteintes.

:::note
Facet livre les notifications dans l’application seulement. Il n’y a pas de
livraison par e-mail.
:::

### 5. Rejouez la visite de bienvenue

Les comptes avec le rôle administrateur intégré voient le chapitre « Visite
de bienvenue ». Allumez « Afficher la visite de bienvenue ». La visite s’ouvre
à votre prochain chargement de l’application.

### 6. Copiez un point de terminaison MCP

Dans « Points de terminaison MCP », Facet liste une URL pour chaque rôle que
vous détenez. Un agent MCP (Model Context Protocol) se connecte à Facet par
cette URL. L’agent agit comme ce rôle. À la première connexion, l’agent se
connecte via un flux dans le navigateur. Sélectionnez « Copier » pour copier l’URL.

### 7. Gérez vos clés d’API

Une clé d’API laisse un client machine appeler l’API Facet. La clé agit comme
vous, sous l’un de vos rôles. Ouvrez le menu du compte en bas de la barre
latérale et sélectionnez « Clés API ».

**Créez une clé**

1. Sélectionnez « Créer une clé ».
2. Dans « Nom », tapez un libellé. Vous seul le voyez. Jusqu’à 100 caractères.
3. Dans « Rôle », choisissez l’un de vos rôles attribués. La clé ne peut faire
   que ce que ce rôle permet.
4. Dans « Expire le », choisissez une date. Laissez vide pour une clé qui
   n’expire jamais.
5. Sélectionnez « Créer une clé ».
6. Facet montre la clé en clair une seule fois. Sélectionnez « Copier » et
   gardez-la en lieu sûr.

:::caution
Facet montre la clé en clair une seule fois. Vous ne pourrez pas la récupérer
plus tard. Si vous la perdez, créez une nouvelle clé.
:::

**Utilisez une clé**

Le client envoie la clé dans l’en-tête `Authorization: Bearer`. Une vraie clé
commence par `fct_`. Cet exemple appelle l’API Facet avec une cléà :

```sh
export FACET_API_KEY="fct_paste-the-key-you-copied"
curl -k https://facet.localhost:3443/Api/iam/me \
  -H "Authorization: Bearer $FACET_API_KEY"
```

Facet répond avec votre profil de compte en JSON. L’indicateur `-k` saute la
vérification du certificat TLS de l’adresse de développement.

**Révoquez une clé**

1. Dans la liste des clés, sélectionnez « Révoquer » sur la ligne de la clé.
2. Confirmez avec « Révoquer la clé ».

Les clients qui utilisent la clé cessent de fonctionner aussitôt. La ligne
reste dans la liste avec le badge « Révoquée ». La liste montre le nom, le
préfixe, le rôle, l’heure de « Dernière utilisation », l’heure d’« Expire le »
et le statut de chaque cléà : « Active », « Expirée » ou « Révoquée ». Une
clé sans date d’expiration affiche « Jamais ».

:::note
Une clé cesse aussi de fonctionner quand elle expire, quand vous perdez le
rôle, ou quand votre compte est désactivé.
:::

### 8. Relisez vos sessions actives

Dans « Sessions actives », Facet liste vos sessions courantes, une ligne par
appareil ou application. Chaque ligne montre l’appareil ou l’application,
l’adresse IP, le rôle que la session porte, et les heures « Créé » et
« Dernière utilisation ». Une ligne sans détails d’appareil affiche
« Appareil inconnu ».

**Déconnectez un appareil**

1. Sélectionnez « Révoquer » sur la ligne de session.
2. Confirmez avec « Révoquer la session ».

L’appareil se déconnecte à son prochain rafraîchissement.

**Déconnectez tous les autres appareils**

1. Sélectionnez « Révoquer les autres sessions ».
2. Confirmez avec « Révoquer les autres ».

Votre session courante reste connectée. Facet rapporte combien de sessions il
a révoquées. Une liste vide affiche « Aucune session active. ».

:::note
Un token d’accès déj à émis continue de fonctionner jusqu’à son expiration,
pour quelques minutes par défaut. Après, l’appareil doit se reconnecter.
:::

## Dépannage

### L’entrée Clés API manque dans le menu du compte

Votre rôle actif ne permet pas l’accès d’API. Ouvrez le menu du compte et
essayez « Changer de rôle », ou demandez à votre administrateur.

### Vous ne pouvez pas créer de clé

Vérifiez ces champs et réessayezà :

1. Le rôle doit être l’un de vos rôles attribués.
2. Le rôle doit permettre l’accès d’API.
3. La date d’expiration doit être dans le futur.

### La clé ne fonctionne pas

1. Vérifiez que le client envoie la clé complète dans l’en-tête
   `Authorization: Bearer`.
2. Ouvrez « Clés API » et vérifiez le statut. Les clés « Révoquée » et
   « Expirée » ne fonctionnent plus jamais. Créez une nouvelle clé.

### Un appareil fonctionne encore un moment après votre révocation

Un token d’accès déj à émis reste valable jusqu’à son expiration, pour
quelques minutes par défaut. Après, l’appareil doit se reconnecter.

## Voir aussi

- [Connexion, MFA et mot de passe](/fr/workspace/sign-in-mfa/) — connexion,
  configuration du second facteur, et réinitialisation du mot de passe.
- [Notifications](/fr/workspace/notifications/) — ce que contrôle la
  préférence de notification dans l’application.
- [Contextes d’authentification](/fr/concepts/auth-contexts/) — comment une
  session ou une clé d’API se résout en un rôle.
- [Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/) —
  ce qu’un rôle peut permettre pour vous et pour vos clés.
- [Référence](/fr/reference/) — les points de terminaison d’API qu’une clé
  peut appeler.
