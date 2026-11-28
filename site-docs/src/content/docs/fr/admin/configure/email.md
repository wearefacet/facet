---
title: Courriel sortant
description: Configurez l’envoi de courriel sortant via SMTP, passez le contrôle de production et testez la livraison avec la sonde intégrée.
type: how-to
audience: [operator]
features: [AUT-07]
sidebar:
  order: 3
verified_at: eee55a2
---

Un nouvel arrivant n’a pas reçu le lien d’invitation, et la réinitialisation
de mot de passe n’a pas abouti non plus. Facet envoie du courriel pour les
flux d’identifiants : les liens d’invitation pour les premiers identifiants
et les réinitialisations de mot de passe. La livraison passe par un seul
adaptateur de courriel. L’adaptateur par défaut imprime le courriel sur
stdout. La production exige une vraie livraison par SMTP. Les notifications
dans l’application forment un système séparé qui n’utilise jamais le
courriel.

## Quand l’utiliser

Configurez le courriel quand :

- Vous installez SMTP pour une nouvelle installation.
- Vous faites passer une installation de la livraison stdout à un relais.
- Vous changez l’adresse d’expédition sans redémarrer.

## Avant de commencer

- Vous disposez d’un compte de relais SMTP : hôte, port, identifiant, mot
  de passe.
- Vous connaissez la valeur de `APP_ENV` du déploiement.
- Les clés `mail:` sont des clés chaudes. Un enregistrement de paramètres
  surpasse le fichier sans redémarrage — voir
  [Paramètres système](/fr/admin/configure/system-settings/).

## Étapes

### 1. Définissez la section mail

Placez les valeurs SMTP dans `config.{env}.yml` :

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
| `mail.smtp.use_tls` | `true` | Passe la connexion en TLS via STARTTLS. |

### 2. Passez le contrôle de production

Le démarrage refuse `adapter: dev` quand `APP_ENV=production` et que le
fichier ne définit pas l’échappatoire. L’erreur nomme les clés exactes des
deux voies :

- Réglez `mail.adapter: smtp` avec les clés `mail.smtp.*` — la voie normale.
- Ou réglez `mail.allow_dev_adapter_in_production: true` — la voie hors
  réseau. Le courriel reste sur stdout.

:::caution
Chaque environnement qui démarre avec l’adaptateur `dev` journalise un
avertissement. Un courriel qui ne s’imprime que sur stdout n’atteint jamais
les utilisateurs. Un courriel de réinitialisation perdu signifie un compte
verrouillé. Testez la livraison avant d’ouvrir l’installation aux
utilisateurs.
:::

Le même contrôle s’applique à l’écriture. Un enregistrement d’exécution qui
bascule l’adaptateur effectif vers `dev` sous `APP_ENV=production` est
refusé, sauf si le fichier définit le même échappatoire. L’échappatoire
lui-même reste propre au fichier.

### 3. Changez les valeurs sans redémarrer

Les clés `mail.*` sont chaudes. Épinglez-les sur la page
**Configurer → Plateforme → Paramètres**, ou enregistrez le document de
paramètres :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"mail": {"from_address": "no-reply@your-company.tld"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

Un enregistrement de paramètres reconstruit l’adaptateur ; le prochain
courriel utilise donc les nouvelles valeurs. Le contrôle d’écriture vérifie
l’état fusionné : `mail.adapter: smtp` exige un `mail.smtp.host` non null.

### 4. Testez la livraison

La page des paramètres possède une sonde pour cela. Ouvrez
**Configurer → Plateforme → Paramètres**, cherchez
**Envoyer un courriel de test**, tapez le destinataire et sélectionnez
**Envoyer un courriel de test**. Un courriel traverse le connecteur
enregistré — le même chemin que les réinitialisations de mot de passe et les
invitations. Enregistrez d’abord toute modification en attente ; le test
utilise les paramètres enregistrés, pas le formulaire.

Les réponses possibles :

| Réponse | Signification |
| --- | --- |
| `200 {adapter, from_address, to}` | Livré. La réponse nomme le transport et l’expéditeur utilisés. |
| `422` | Facet a refusé avant le réseau : le connecteur est encore `dev`, ou l’adresse est mal formée. |
| `502` | Le transport a échoué. Le message porte l’erreur propre du relais — `connection refused` ou un échec d’authentification 535 est le diagnostic que vous cherchiez en pressant le bouton. |

Sur une installation qui tourne encore avec l’adaptateur `dev`, la sonde
refuse avec :

```json
{"error": "The email connector is off: the 'dev' adapter prints to stdout and delivers nothing. Set mail.adapter to smtp and save before testing"}
```

En second contrôle, déclenchez une réinitialisation de mot de passe depuis
la page de connexion. Le lien de réinitialisation arrive uniquement par
courriel ; un courriel livré prouve donc toute la chaîne : adaptateur,
relais, adresse d’expédition et TTL du lien. Le TTL du lien est
`iam.change_password_expiration`, 24 heures par défaut.

## Exemple

Une installation hors réseau qui doit garder la livraison stdout, avec
l’échappatoire défini :

```yaml
mail:
  adapter: dev
  allow_dev_adapter_in_production: true
  from_address: no-reply@your-company.tld
  from_name: Facet
```

Chaque courriel s’imprime sur stdout. La sonde refuse ici de signaler un
succès — cela ne prouverait rien, car aucune boîte de réception n’a rien
reçu. Accompagnez cette posture d’un flux opérateur qui surveille les logs
du backend, car les liens de réinitialisation et d’invitation n’atteignent
jamais une boîte de réception.

## Dépannage

**Le démarrage échoue avec une erreur d’adaptateur de courriel.**

La production refuse l’adaptateur `dev` sans l’échappatoire. Suivez les deux
voies du message d’erreur, ou voyez l’étape 2.

**Le courriel de test répond `502`.**

Lisez le message : c’est l’erreur propre du relais. Un mauvais port,
`use_tls: false` face à un relais qui n’accepte que TLS et les échecs
d’authentification du relais sont les causes courantes. Corrigez la valeur,
enregistrez et renvoyez la sonde.

**Le courriel n’arrive pas.**

Cherchez la tentative d’envoi dans les logs du backend, puis lancez la sonde
— elle transforme l’échec silencieux en erreur nommée. Déclenchez une
réinitialisation de mot de passe pour retester le flux de lien.

**Un enregistrement d’exécution de l’adaptateur est refusé.**

Le contrôle d’écriture exige un `mail.smtp.host` non null quand l’adaptateur
vaut `smtp`, et refuse `dev` en production sans l’échappatoire du fichier.

**La nouvelle adresse d’expédition ne s’applique pas.**

Une valeur épinglée l’emporte sur le fichier. Vérifiez les épinglages sur la
page des paramètres, ou enregistrez la nouvelle valeur via le document de
paramètres.

**Le lien de réinitialisation a expiré.**

Le TTL du lien est `iam.change_password_expiration`, 86 400 secondes par
défaut. Demandez un lien neuf.

## Voir aussi

- [Fichiers de configuration](/fr/admin/configure/configuration-files/) —
  où vit la section `mail:`.
- [Paramètres système](/fr/admin/configure/system-settings/) — l’étage
  d’exécution qui surpasse le fichier.
- [Notifications dans l’application](/fr/use/notifications/) — le système
  de notifications séparé.
- [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/) — les
  TTL des liens et les règles de verrouillage.
- [Premier démarrage et initialisation](/fr/admin/install/bootstrap/) —
  `seed:admin`, qui imprime son mot de passe au lieu de l’envoyer par
  courriel.
- Internes sur GitHub : [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
