---
title: Imposer le MFA
description: "Activez le MFA (authentification multifacteur) pour l’instance, choisissez le niveau d’application, et gérez la récupération."
type: how-to
audience: [admin]
features: [IAM-03, PLT-02]
verified_at: eee55a2
sidebar:
  order: 7
---

Un mot de passe volé ne doit pas ouvrir la liste des clients de Brightwater.
Ravi demande à chaque compte un second facteur : un code à six chiffres issu
d’une application d’authentification. Facet appelle cela l’authentification
multifacteur (MFA). Il choisit si les comptes sont *invités* à s’enrôler ou
*doivent* s’enrôler, et il garde le chemin de récupération prêt pour le jour
où quelqu’un perd son téléphone.

Le facteur est un mot de passe à usage unique basé sur le temps (TOTP), tel
que spécifié par la RFC 6238 : un code à 6 chiffres qui change toutes les 30
secondes. Le compte garde le secret partagé dans une application
d’authentification. Chaque compte porte aussi des codes de secours à usage
unique comme chemin d’auto-récupération.

## Quand l’utiliser

- Vous devez exiger un second facteur à la connexion pour chaque compte.
- Vous devez libérer un compte qui a perdu son authentificateur.
- Vous devez expliquer pourquoi une connexion s’arrête sur un écran
  d’enrôlement.

## Avant de commencer

- **La bonne page.** Les réglages d’exécution vivent sur **Configurer →
  Plateforme → Paramètres**, dans le chapitre Sécurité. Il vous faut le
  droit `update` sur `core.SystemSettings`. Les rôles `editor` et `viewer`
  créés par l’initialisation ont le chemin retranché de leurs attributions,
  si bien que la posture par défaut est réservée aux administrateurs.
- **Le côté du membre.** Lisez
  [Se connecter, MFA, réinitialiser votre mot de passe](/fr/use/first-day/sign-in/)
  pour le côté titulaire du compte.

## Les deux niveaux d’application

| Niveau      | Comportement                                                                                                                                          |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `preferred` | Facet demande à chaque compte non enrôlé de configurer le MFA après la connexion. Le compte peut décliner. Facet redemande à la prochaine connexion. |
| `always`    | Facet retient chaque connexion non enrôlée à l’étape d’enrôlement. Aucune session n’existe tant que le compte n’a pas vérifié un premier code.       |

Sous `always`, la retenue n’a ni retour ni annulation. L’étape d’enrôlement
n’offre aucune sortie, et le refresh du token demande une session qui
n’existe pas encore. Une organisation qui veut une sortie utilise
`preferred`.

:::caution
Passez à `always` en connaissance de cause. Chaque compte sans MFA s’arrête
à l’écran d’enrôlement à sa prochaine connexion, administrateurs compris.
:::

## Les deux étages de configuration

| Étage      | Où                    | Clés                                                                                                          |
| ---------- | ---------------------- | --------------------------------------------------------------------------------------------------------------- |
| Exécution  | `core.SystemSettings`  | `iam.mfa.type` (`none` ou `totp`), `iam.mfa.enforcement` (`preferred` ou `always`)                          |
| Fichier    | `config.{env}.yml`     | `iam.mfa.totp.enabled` (un booléen ; `true` se traduit en type `totp`, `false` en `none`), `iam.mfa.enforcement` |

La valeur d’exécution gagne quand elle est positionnée. Un champ
d’exécution null signifie « suivre le fichier ». Chaque décision
d’authentification lit directement la ligne du document d’exécution, jamais
un cache ; un enregistrement s’applique donc aussitôt.

Les deux fichiers de configuration livrés avec le serveur portent la même
section. Extrait de `config.dev.yml` :

```yaml
iam:
  mfa:
    totp:
      enabled: true
      window: 1
      issuer: "Facet"
```

`window: 1` accepte un code de l’étape précédente ou suivante, si bien qu’une
saisie lente passe encore. `issuer` est le nom que montre l’application
d’authentification — sur l’instance en cours, l’URI d’enrôlement se lit
`otpauth://totp/Facet:tom@brightwater.example?secret=…`.

## Étapes

### 1. Positionner la politique d’exécution

Ouvrez **Configurer → Plateforme → Paramètres** et allez au chapitre
Sécurité. Mettez **Type de facteur MFA** à `totp`, puis réglez
**Application du MFA**. Le sélecteur d’application ne s’affiche que tant que
le type de facteur est `totp`. Sélectionnez **Enregistrer**.

<!-- screenshot: configure-settings-security -->

La page envoie une mise à jour partielle par la route de document standard :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"iam": {"mfa": {"type": "totp", "enforcement": "always"}}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

La barrière d’écriture n’accepte que `none` ou `totp` pour le type, et
seulement `preferred` ou `always` pour l’application. Une valeur fausse
répond `422`. Le hook de cycle de vie Lua refuse tout create et tout delete
du document des réglages ; seule la ligne `settings` créée par
l’initialisation existe.

### 2. Lire les valeurs effectives

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/SystemSettings"
```

La carte `values` porte les valeurs effectives, non secrètes, indexées par
chemin, par exemple `"iam.mfa.enforcement": "always"`. La liste `pinned`
nomme les chemins que le document épingle actuellement ; un chemin absent
suit le fichier.

### 3. Enrôler les comptes

Chaque compte s’enrôle à la connexion :

1. Le compte se connecte avec courriel et mot de passe.
2. Sous `always`, la connexion s’arrête à « Configurer l’authentification à
   deux facteurs ». Sous `preferred`, Facet montre la même configuration
   comme une invite refermable après la connexion.
3. Le compte scanne le code QR, ou colle la clé manuelle, dans une
   application d’authentification. La page de configuration affiche un URI
   `otpauth://`.
4. Le compte tape le code à 6 chiffres et confirme.
5. Facet bascule `mfa_enabled` sur le compte et affiche 10 codes de secours.

L’appel de vérification renvoie les codes de secours une seule fois :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"code": "123456"}' \
  "$(facet-cli host)/Api/iam/mfa/totp/verify"
```

La réponse porte `"backup_codes": [...]` et `"mfa_enabled": true`. Sur
l’instance en cours, les codes arrivent sous cette forme :

```json
{"ok": true, "mfa_enabled": true, "backup_codes": ["384f-0d34", "… nine more …"]}
```

### 4. Informer les comptes des codes de secours

Une série contient 10 codes de 8 caractères hexadécimaux, présentés en
`xxxx-xxxx`. Facet les affiche une fois et ne stocke que leurs hachages
SHA-256. Chaque code marche exactement une fois. Le défi MFA accepte un code
avec `method: "backup_code"`, si bien qu’un authentificateur perdu est un
chemin d’auto-récupération. Un réenrôlement fabrique une série neuve.

### 5. Récupérer un compte

Quand un compte perd son authentificateur et ses codes de secours, un
administrateur efface son MFA :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"account_id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D"}' \
  "$(facet-cli host)/Api/iam/mfa/disable"
```

La route exige la permission `mfa_disable` sur `iam.Account`. Le rôle
`iam.Roles.admin` créé par l’initialisation la détient par `*` sur `*.*`.
N’accordez pas `mfa_disable` à un rôle qu’une application externe peut
élire ; voir
[Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).
L’appel efface le secret stocké, le compteur de rejeu, et les codes de
secours, et met `mfa_enabled` à `false`. Le compte se connecte et s’enrôle
de nouveau.

La page du compte montre **Réinitialiser le MFA** pour cette récupération ;
elle confirme avant l’appel et se cache pour un compte purement fédéré.

## Limites de débit

| Surface                          | Limite                        | Effet                                                              |
| --------------------------------- | ------------------------------ | --------------------------------------------------------------------- |
| Vérification MFA à l’enrôlement   | 5 codes faux par 5 minutes    | Le point d’entrée répond `429` jusqu’à ce que la fenêtre expire.     |
| Défi MFA à la connexion           | 5 réponses fausses            | Le défi est supprimé et le compte se verrouille pendant 5 minutes.   |
| Enrôlement à la connexion         | 5 codes faux sur le token     | Le token meurt et le compte se verrouille.                           |

Un succès remet le compteur à zéro. Voir
[Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/)
pour la gestion du verrouillage.

## Dépannage

### La connexion s’arrête à l’écran d’enrôlement sans retour possible

L’application est `always` et le compte n’est pas enrôlé. Terminez la
configuration, ou un administrateur repasse l’application à `preferred`.

### La vérification répond `429`

Cinq codes faux ont été essayés en moins de 5 minutes. Attendez la fin de
la fenêtre, puis réessayez avec un code frais.

### L’écriture des réglages répond `403`

Votre rôle ne peut ni lire ni mettre à jour `core.SystemSettings`. Les rôles
editor et viewer créés par l’initialisation ont le chemin retranché ;
utilisez un rôle d’administrateur, ou accordez le chemin explicitement.

### Le sélecteur d’application a disparu

Le type de facteur en cours est `none`. Mettez d’abord le type à `totp` ; le
sélecteur apparaît pour l’enregistrement.

### Un code ne marche pas

Les codes changent toutes les 30 secondes. Attendez un code frais et
saisissez-le aussitôt. Vérifiez que l’horloge du serveur est juste ; TOTP en
dépend.

## Voir aussi

- [Se connecter, MFA, réinitialiser votre mot de passe](/fr/use/first-day/sign-in/) —
  les étapes d’enrôlement et de connexion du titulaire du compte.
- [Gérer les comptes](/fr/admin/people/accounts/) — le champ
  `mfa_enabled` et l’action de réinitialisation.
- [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/) —
  le verrouillage que posent les limites de débit.
- [La rétention : ce qui est conservé](/fr/admin/history/retention/) — la
  durée de vie des défis MFA.
- Internes sur GitHub :
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md),
  [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
- [Sécurité et gouvernance](/fr/discover/security/)
- [Clés des paramètres système](/fr/reference/system-settings-keys/)
