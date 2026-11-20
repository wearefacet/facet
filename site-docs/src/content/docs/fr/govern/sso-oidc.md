---
title: Le SSO avec OIDC
description: "Connectez des fournisseurs d’identité, réglez le provisionnement JIT, et passez l’instance au SSO seul."
audience: [admin, operator]
features: [IAM-08, FE-14]
sidebar:
  order: 7
verified_at: fd345fe3
---

Facet connecte les comptes par des fournisseurs d’identité externes avec
OpenID Connect (OIDC). Le serveur démarre un flux de code d’autorisation,
vérifie le token d’identité du fournisseur, et connecte le compte. Vous
configurez chaque fournisseur comme un document, si bien que chaque
changement est audité et réversible.

## Quand l’utiliser

- Votre organisation fait tourner un fournisseur d’identité, et les membres
  doivent se connecter avec leurs comptes professionnels.
- Vous devez décider si des membres inconnus reçoivent un compte
  automatiquement.
- Vous devez arrêter la connexion par mot de passe et ne permettre que le
  fournisseur.

## Avant de commencer

- **Le droit.** Il vous faut les droits `create` et `update` sur
  `iam.OIDCProvider`. Le rôle `admin` créé par l’initialisation les porteà ;
  le rôle `editor` a le doctype retranché de ses attributions.
- **Les détails du fournisseur.** Rassemblez auprès de votre fournisseurà :
  l’URL de l’issuer, le client id, et le client secret.
- **L’adresse de retour.** Positionnez-la chez votre fournisseur sur
  `https://<your-host>/auth/oidc/<name>/callback`.

## Étapes

### 1. Créer le document fournisseur

Ouvrez **Configurer → Plateforme → Fournisseurs d’identité** et
sélectionnez **Ajouter un fournisseur**. Renseignez les champsà :

| Champ            | Contient                                        | Règles                                                                                                                        |
| ----------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `name`            | Le segment d’URL dans `/auth/oidc/{name}`         | Lettres minuscules, chiffres, tirets. Immuable après création.                                                                    |
| `label`           | Le texte du bouton de connexion                   | Par défaut, le nom.                                                                                                               |
| `issuer`          | L’URL issuer du fournisseur                       | Doit être une URL `https` absolue. Le `http` simple n’est accepté que sur un hôte loopback, pour un faux fournisseur de développement. |
| `client_id`       | Le client id OIDC chez le fournisseur             | Venant de l’enregistrement client de votre fournisseur.                                                                           |
| `client_secret`   | Le secret du client confidentiel                  | Stocké dans le magasin de secrets. Le formulaire le dépose hors bandeà ; les documents ne portent qu’un marqueur. Plus jamais affiché. |
| `domains`         | Liste d’autorisation de domaines de courriel      | Entrées en minuscules, par exemple `example.tld`. Vide signifie connexion par lien seulement.                                      |
| `auto_provision`  | Créer des comptes pour les personnes inconnues    | Quand `true`, `default_role` est obligatoire.                                                                                     |
| `default_role`    | Le rôle des comptes provisionnés                  | Appliqué à la création seulement.                                                                                                 |
| `scopes`          | Les scopes OIDC à demander                        | Par défaut `openid`, `email`, `profile`.                                                                                          |
| `enabled`         | L’interrupteur par fournisseur                    | Un fournisseur désactivé refuse comme un nom inconnu.                                                                             |

Vous pouvez aussi créer le fournisseur par l’API de documentà :

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "corp-idp",
    "label": "Company sign-in",
    "issuer": "https://idp.example.tld",
    "client_id": "facet-prod",
    "domains": ["example.tld"],
    "auto_provision": false,
    "enabled": true
  }' \
  "https://facet.localhost:3443/Api/iam/OIDCProvider"
```

Le hook de création valide les champs et répond `422` sur une valeur
fausse. Le client secret voyage par un appel de dépôt séparé, jamais dans
le corps du document.

### 2. Vérifier la page de connexion

Ouvrez la page de connexion dans une fenêtre privée. Sous le formulaire de
mot de passe, Facet montre un bouton **Continuer avec** par fournisseur
activé. La liste des boutons vient d’une lecture publiqueà :

```sh
curl "https://facet.localhost:3443/Api/iam/oidc/providers"
```

La réponse ne porte que le mode d’authentification et les noms
d’affichage. L’issuer, le client id, et le secret ne quittent jamais le
serveur.

### 3. Décider qui reçoit un compte

Deux chemins font entrer une personne inconnueà :

- **Le rattachement.** Le fournisseur renvoie un courriel vérifié dont le
  domaine est dans la liste d’autorisation, et un compte avec ce courriel
  existe. Facet rattache l’identité à ce compte et connecte la personne. La
  clé de jointure est la paire nom du fournisseur et sujet côté
  fournisseur, jamais le courrielà ; un changement de courriel chez le
  fournisseur ne peut donc pas s’emparer du compte.
- **Le provisionnement à la volée (JIT).** L’identité est inconnue, le
  courriel est vérifié et dans la liste d’autorisation, et
  `auto_provision` est allumé. Facet crée le compte avec le `default_role`
  du fournisseur et connecte la personne. Le lien est stocké dans le
  tableau `federated_identities` du compte.

  Les comptes de service ne se fédèrent jamais. Un compte `suspended` ou
  `disabled` refuseà ; la raison reste dans le journal d’audit.

  La vérification MFA locale ne s’applique pas sur ce chemin. Le
  fournisseur est le facteur de référenceà ; voir
  [Imposer le MFA](/fr/govern/enforcing-mfa/) pour le chemin par mot de
  passe.

### 4. Lire la piste d’audit

Trois événements atterrissent dans le journal des connexionsà :

| Événement          | Écrit quand                                                          |
| -------------------- | ---------------------------------------------------------------------- |
| `oidc_provisioned`   | Facet a créé un compte par le JIT.                                      |
| `oidc_login`         | Une connexion OIDC a émis une session.                                  |
| `oidc_denied`        | N’importe quel refus. Les détails portent la raison lisible par machine. |

Voir [Auditer l’activité](/fr/govern/auditing-activity/) pour lire le
journal. Le navigateur ne voit toujours qu’une erreur génériqueà ; la raison
ne l’atteint jamais.

### 5. Exiger le SSO

Ouvrez **Configurer → Plateforme → Paramètres**, chapitre Sécurité, et
réglez **Mode d’authentification**. Les deux modesà :

| Mode                  | Comportement                                                                                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hybrid` (par défaut)  | La connexion par mot de passe et la connexion par fournisseur fonctionnent toutes deux.                                                                     |
| `oidc_only`            | La route du mot de passe refuse avec `403` et écrit un événement `password_login_denied`. La réinitialisation du mot de passe et l’amorçage du premier identifiant refusent avec `422`. La page de connexion cache le formulaire de mot de passe et le lien de réinitialisation. |

La barrière d’écriture refuse un enregistrement qui met `oidc_only` alors
qu’aucun fournisseur activé n’existeà ; un enregistrement ne peut donc pas
fermer tous les chemins de connexion.

:::caution
Sous `oidc_only`, une personne dont l’identité n’est pas rattachée et dont
le fournisseur est en panne ne peut pas se connecter. Gardez une session
de secours, ou prévoyez la commande de récupération ci-dessous.
:::

### 6. Se remettre d’un verrouillage

Quand le seul fournisseur activé est mort et qu’aucune session ne survit,
lancez sur l’hôte du serveurà :

```sh
facet auth:mode hybrid
```

La commande met le mode sur le document des réglages par le chemin
d’écriture normal. Les barrières de politique lisent directement la ligne
du document, si bien que chaque serveur en marche applique le mode
aussitôt, sans redémarrage.

## Dépannage

### La connexion revient à la page de connexion avec une erreur générique

Le journal d’audit garde la raison sous `oidc_denied`. Causes courantesà :
un client secret faux, un issuer faux, une adresse de retour qui ne
correspond pas, ou un fournisseur désactivé.

### Une personne ne peut pas se connecter et aucune erreur ne s’affiche

Vérifiez le statut de son compte. Un compte `suspended` ou `disabled`
refuse sur chaque chemin.

### Un nouveau membre ne reçoit pas de compte

Le JIT demande les quatre conditionsà :

1. Une identité inconnue.
2. Un courriel vérifié.
3. Un domaine dans la liste d’autorisation.
4. `auto_provision` allumé.

Vérifiez le document du fournisseur.

### L’écriture des réglages refuse `oidc_only` avec `422`

Aucun fournisseur activé n’existe. Activez ou créez-en un d’abord.

### Le bouton du fournisseur ne s’affiche pas

Le fournisseur est désactivé, ou la page de connexion n’a pas réussi à

lire la liste publique des fournisseurs. Vérifiez
`GET /Api/iam/oidc/providers`.

## Voir aussi

- [Se connecter, MFA, réinitialiser votre mot de passe](/fr/workspace/sign-in-mfa/) —
  les étapes de connexion du côté titulaire du compte.
- [Gérer les comptes](/fr/govern/accounts-lifecycle/) — le champ
  `federated_identities` sur le compte.
- [Affecter les rôles et l’élection](/fr/govern/assigning-roles-election/) —
  le rôle que reçoit un compte provisionné.
- [Imposer le MFA](/fr/govern/enforcing-mfa/) — pourquoi la barrière MFA ne
  s’applique pas sur ce chemin.
- [Auditer l’activité](/fr/govern/auditing-activity/) — le journal des
  connexions.
- Internes sur GitHubà :
  [oidc.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oidc.md).
