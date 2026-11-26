---
title: Connexion, MFA et mot de passe
description: Se connecter à Facet, activer l’authentification multifacteur (MFA) et réinitialiser votre mot de passe.
audience: [user]
features: [FE-01, IAM-01, IAM-03, IAM-04, IAM-05, IAM-10]
sidebar:
  order: 1
verified_at: 49d7c7e5
---

Vous vous connectez à Facet avec votre adresse e-mail et votre mot de passe.
Votre organisation peut exiger une seconde vérification à la connexion :
l’authentification multifacteur (MFA). Les écrans de connexion l’appellent
authentification à deux facteurs. Cette page couvre la connexion, les premiers
mots de passe, la MFA et la réinitialisation du mot de passe.

## Avant de commencer

- **Le premier mot de passe.** Il vient de votre administrateur : un mot
  de passe temporaire ou un lien d’invitation dans un e-mail.
- **Une application d’authentification.** Pour la MFA, il vous faut une
  application. Facet fonctionne avec des applications comme 1Password, Authy
  et Aegis.

## Étapes

### 1. Ouvrez la page de connexion

Ouvrez `https://facet.localhost:3443` dans votre navigateur, ou l’adresse que
votre organisation vous donne. La page montre « E-mail », « Mot de passe », et
un bouton « Se connecter ».

### 2. Saisissez votre e-mail et votre mot de passe

1. Tapez votre adresse e-mail dans « E-mail ».
2. Tapez votre mot de passe dans « Mot de passe ».
3. Sélectionnez « Se connecter ».

Quand le mot de passe est faux, Facet affiche les tentatives qui restent.
Après trop d’essais ratés, la connexion se verrouille pendant environ
5 minutes.

### 3. Définissez votre premier mot de passe

Votre première connexion dépend de l’identifiant que votre administrateur a
envoyé.

- **Un mot de passe temporaire.** Connectez-vous avec. Facet affiche
  « Définir un nouveau mot de passe ». Saisissez le mot de passe actuel, un
  nouveau mot de passe d’au moins 8 caractères, puis répétez le nouveau mot de
  passe. Sélectionnez « Enregistrer le mot de passe et continuer ». Facet vous
  connecte avec le nouveau mot de passe.
- **Un lien d’invitation.** Ouvrez le lien de l’e-mail. La page affiche
  « Choisir un nouveau mot de passe ». Saisissez un nouveau mot de passe
  d’au moins 8 caractères et sélectionnez « Définir le mot de passe ». Facet
  vous connecte.

### 4. Saisissez le code de votre application d’authentification

Si votre compte a la MFA, la connexion s’arrête à l’écran « Authentification
à deux facteurs ».

1. Ouvrez votre application d’authentification.
2. Tapez le code à 6 chiffres pour Facet.
3. Sélectionnez « Vérifier ».

Le code change toutes les 30 secondes. Si vous n’avez pas accès à

l’application, sélectionnez « Utiliser un code de secours » et saisissez
l’un de vos codes enregistrés.

### 5. Configurez la MFA quand Facet le demande

Facet peut vous demander de configurer la MFA pendant la connexion :

- **Votre organisation exige la MFA.** La connexion s’arrête à « Configurer
  l’authentification à deux facteurs » jusqu’à ce que vous terminiez. L’écran
  ne propose aucun retour en arrière.
- **Votre organisation recommande la MFA.** Après la connexion, Facet affiche
  la même configuration. Vous pouvez sélectionner « Passer pour l’instant ». Facet
  redemande à votre prochaine connexion.

  Pour configurer la MFA :

1. Scannez le QR code avec votre application d’authentification. Si vous ne
   pouvez pas scanner, sélectionnez « Copier le secret dans le presse-papiers »
   et collez la clé de « Clé de saisie manuelle » dans votre application.
2. Tapez le code à 6 chiffres de l’application et sélectionnez « Vérifier et
   activer ».
3. Facet affiche 10 codes de secours sous la forme `xxxx-xxxx`.
4. Conservez les codes en lieu sûr. Chaque code fonctionne une seule fois,
   quand votre application d’authentification n’est pas disponible.
5. Sélectionnez « J’ai enregistré mes codes de secours ».

:::caution
Facet affiche les codes de secours une seule fois. Si vous les perdez et
perdez aussi votre application d’authentification, un administrateur doit
réinitialiser la MFA de votre compte.
:::

:::note
Vous configurez la MFA à la connexion. Les pages de réglages n’ont pas de
section MFA.
:::

### 6. Connectez-vous avec l’authentification unique

Si votre organisation a configuré l’authentification unique (SSO), la page de
connexion montre un bouton « Continuer avec » par fournisseur. Sélectionnez
votre fournisseur et suivez ses étapes. Quand le serveur exige le SSO, les
champs de mot de passe et le lien « Mot de passe oublié ? »
n’apparaissent pas.

Si la connexion avec le fournisseur ne se termine pas, Facet revient à la page
de connexion. Réessayez. Si l’échec se répète, contactez votre administrateur.

### 7. Réinitialisez votre mot de passe par e-mail

Vous n’avez pas besoin d’être connecté pour réinitialiser un mot de passe.

1. Ouvrez la page de connexion et sélectionnez « Mot de passe oublié ? ».
2. Tapez votre adresse e-mail dans « Identifiant ».
3. Sélectionnez « Envoyer le lien de réinitialisation ».
4. Facet affiche « Vérifiez votre boîte de réception » et la durée de validité
   du lien.
5. Ouvrez l’e-mail et sélectionnez le lien. Vérifiez le dossier des
   indésirables si l’e-mail n’arrive pas.
6. La page affiche « Choisir un nouveau mot de passe ». Tapez un nouveau mot
   de passe d’au moins 8 caractères et sélectionnez « Définir le mot de
   passe ».
7. Facet revient à la page de connexion et affiche « Mot de passe mis à jour.
   Connectez-vous avec votre nouveau mot de passe. »

### 8. Déconnectez-vous

1. Sélectionnez votre nom en bas de la barre latérale.
2. Sélectionnez « Déconnexion ».

Votre session se termine aussi quand elle expire (14 jours par défaut), quand
vous la révoquez dans vos réglages, ou quand Facet détecte un token de session
réutilisé. Voir
[Paramètres, sessions et clés API](/fr/use/account/)
pour relire vos sessions.

## Dépannage

### Le mot de passe ne fonctionne pas

1. Vérifiez l’adresse e-mail et le mot de passe pour des fautes de frappe.
2. Vérifiez que Caps Lock est désactivé. Le message d’erreur affiche les
   tentatives qui restent.
3. Attendez et réessayez. Après trop d’essais ratés, la connexion se
   verrouille pendant environ 5 minutes.

### Le code ne fonctionne pas

Attendez un code frais et saisissez-le aussitôt. Un code déjà utilisé ne
fonctionne plus. Après 5 codes faux, la connexion se verrouille pendant
environ 5 minutes.

### Vous avez perdu votre application d’authentification

1. Sélectionnez « Utiliser un code de secours » sur l’écran « Authentification
  à deux facteurs ».
2. Saisissez l’un des codes que vous avez enregistrés. Chaque code fonctionne
   une seule fois.
3. Demandez à un administrateur de réinitialiser la MFA. Puis connectez-vous
   et reconfigurez la MFA.

### L’étape du code a expiré

L’étape du code reste ouverte 5 minutes. Quand elle se ferme, Facet affiche
« La session de vérification a expiré. Veuillez vous reconnecter. » Reprenez
au début et saisissez un code frais.

### Le lien de réinitialisation ne fonctionne pas

Un lien fonctionne une seule fois et expire après 24 heures par défaut. Quand
Facet affiche « Ce lien de réinitialisation est invalide ou a expiré. »,
demandez un nouveau lien. Sélectionnez « Mot de passe oublié ? » sur la
page de connexion. Un nouveau lien remplace un lien plus ancien.

### Aucun e-mail de réinitialisation n’est arrivé

Vérifiez le dossier des indésirables. Facet affiche la même confirmation pour
chaque adresse. Il ne peut pas vous dire si le compte existe. Si aucun e-mail
n’arrive, demandez à votre administrateur.

## Voir aussi

- [Paramètres, sessions et clés API](/fr/use/account/) —
  relisez vos sessions actives et créez des clés API.
- [Sécurité et gouvernance](/fr/discover/security/) — comment Facet
  protège les comptes, les sessions et les secrets.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) — comment Facet
  applique votre rôle actif à chaque requête.
- [Le tableau de bord](/fr/use/first-day/dashboard/) — la première page après la
  connexion.
