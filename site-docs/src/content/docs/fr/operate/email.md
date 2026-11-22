---
title: Envoi des mails
description: Configurez l’envoi des mails via SMTP, passez le contrôle de production et changez les réglages sans redémarrage.
audience: [operator]
features: [AUT-07]
sidebar:
  order: 7
verified_at: 008dd880
---

Facet envoie des mails pour les parcours d’identifiants : réinitialisation
de mot de passe, invitations, premiers identifiants et liens d’activation de la
MFA. La livraison passe par un seul adaptateur de mail. L’adaptateur par défaut
imprime les mails sur stdout. La production exige une vraie livraison via SMTP.
Les notifications dans l’application forment un système à part, qui n’utilise
jamais le mail.

## Quand l’utiliser

Configurez le mail dans ces cas :

- vous installez SMTP pour une nouvelle installation ;
- vous faites passer une installation de la livraison stdout à un relais ;
- vous changez l’adresse d’expédition sans redémarrer.

## Avant de commencer

- Vous disposez d’un compte de relais SMTP : hôte, port, identifiant, mot
  de passe.
- Vous connaissez le `APP_ENV` du déploiement.
- Les clés `mail:` sont des clés à chaud. Un enregistrement des paramètres
  l’emporte sur le fichier sans redémarrage — voir
  [Paramètres système](/fr/operate/system-settings/).

## Étapes

### 1. Définissez la section mail

Renseignez les valeurs SMTP dans `config.{env}.yml` :

```yaml
mail:
  adapter: smtp
  from_address: no-reply@your-company.tld
  from_name: Facet
  smtp:
    host: smtp.example.tld
    port: 587
    username: relay-user
    password: !env FACET_SMTP_PASSWORD
    use_tls: true
```

Les clés et leurs valeurs par défaut :

| Clé | Valeur par défaut | Signification |
| --- | --- | --- |
| `mail.adapter` | `dev` | `dev` imprime sur stdout. `smtp` livre. |
| `mail.from_address` | `no-reply@facet.local` | L’adresse d’expédition. |
| `mail.from_name` | `Facet` | Le nom d’affichage de l’expéditeur. |
| `mail.smtp.host` | `localhost` | L’hôte du relais. |
| `mail.smtp.port` | `587` | Le port du relais. |
| `mail.smtp.username` | aucune | L’utilisateur du relais, quand le relais en demande un. |
| `mail.smtp.password` | aucune | Le mot de passe du relais. Utilisez `!env` pour le tenir hors du fichier. |
| `mail.smtp.use_tls` | `true` | Utilise TLS vers le relais. |

### 2. Passez le contrôle de production

Le démarrage refuse `adapter: dev` quand `APP_ENV=production` et que le fichier
ne définit pas la porte de sortie. L’erreur nomme les clés exactes des deux
voies :

- Définissez `mail.adapter: smtp` avec les clés `mail.smtp.*` — la voie
  normale.
- Ou définissez `mail.allow_dev_adapter_in_production: true` — la voie des
  installations isolées du réseau. Le mail reste sur stdout.

:::caution
Chaque environnement qui démarre avec l’adaptateur `dev` journalise un
avertissement. Un mail qui ne fait qu’imprimer sur stdout n’atteint jamais les
utilisateurs. Un mail de réinitialisation perdu, et le compte est verrouillé.
Testez la livraison avant d’ouvrir l’installation aux utilisateurs.
:::

Le même contrôle s’applique à l’écriture. Un enregistrement à chaud qui fait
passer l’adaptateur effectif à `dev` sous `APP_ENV=production` est refusé,
sauf si le fichier définit la même porte de sortie. La porte de sortie, elle,
ne se définit que dans le fichier.

### 3. Changez les valeurs sans redémarrage

Les clés `mail.*` sont à chaud. Épinglez-les sur la page
**Configurer → Plateforme → Paramètres**, ou enregistrez le document de
paramètres :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mail": {"from_address": "no-reply@your-company.tld"}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

Un enregistrement des paramètres reconstruit l’adaptateur : le mail
suivant utilise les nouvelles valeurs. Le contrôle à l’écriture vérifie l’état
fusionné : `mail.adapter: smtp` exige un `mail.smtp.host` non nul.

### 4. Testez la livraison

Lancez une réinitialisation de mot de passe depuis la page Connexion. Le lien
de réinitialisation arrive uniquement par mail, donc un mail bien livré prouve
toute la chaîne : adaptateur, relais, adresse d’expédition et TTL du
lien. Le TTL du lien est `iam.change_password_expiration`, 24 heures par
défaut.

## Exemple

Une installation isolée du réseau qui doit garder la livraison stdout, avec la
porte de sortie définie :

```yaml
mail:
  adapter: dev
  allow_dev_adapter_in_production: true
  from_address: no-reply@your-company.tld
  from_name: Facet
```

Chaque mail s’imprime sur stdout. Associez-y un flux opérateur qui surveille
les logs du backend, car les liens de réinitialisation et d’invitation
n’atteignent jamais une boîte de réception.

## Dépannage

**Le démarrage échoue avec une erreur d’adaptateur de mail.**

La production refuse l’adaptateur `dev` sans la porte de sortie. Suivez les
deux voies indiquées dans le message d’erreur, ou voyez l’étape 2.

**Le mail n’arrive pas.**

Cherchez la tentative d’envoi dans les logs du backend. Puis examinez le
relais : mauvais port, `use_tls: false` face à un relais qui n’accepte
que TLS, et échecs d’authentification au relais sont les causes courantes.
Relancez une réinitialisation de mot de passe pour retester.

**Un enregistrement à chaud de l’adaptateur est refusé.**

Le contrôle à l’écriture exige un `mail.smtp.host` non nul quand l’adaptateur
vaut `smtp`, et refuse `dev` en production sans la porte de sortie dans le
fichier.

**La nouvelle adresse d’expédition ne s’applique pas.**

Une valeur épinglée l’emporte sur le fichier. Vérifiez les épinglages sur la
page des paramètres, ou enregistrez la nouvelle valeur via le document de
paramètres.

**Le lien de réinitialisation a expiré.**

Le TTL du lien est `iam.change_password_expiration`, 86 à 400 secondes par
défaut. Demandez un nouveau lien.

## Voir aussi

- [Fichiers de configuration](/fr/operate/configuration-files/) — où se trouve
  la section `mail:`.
- [Paramètres système](/fr/operate/system-settings/) — la couche à chaud qui
  l’emporte sur le fichier.
- [Notifications dans l’application](/fr/workspace/notifications/) — le
  système de notifications distinct.
- [Sessions, tokens et verrouillages](/fr/govern/sessions-tokens-lockouts/) —
  les TTL des liens et les règles de verrouillage.
- [Bootstrap et tâches CLI](/fr/operate/bootstrap-cli/) — `seed:admin`, qui
  imprime son mot de passe au lieu de l’envoyer par mail.
- Internes sur GitHub :
  [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md),
  [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
