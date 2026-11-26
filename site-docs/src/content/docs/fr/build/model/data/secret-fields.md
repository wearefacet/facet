---
title: Champs secrets et en écriture seule
description: Conservez les informations d’authentification dans le magasin de secrets et acceptez des valeurs que Facet ne stocke ni ne renvoie jamais.
audience: [author, admin]
features: [DOC-09, PLT-03]
sidebar:
  order: 9
verified_at: fd345fe3
---

Deux réglages de champ gardent les valeurs sensibles à l’abri des regards, et
ils résolvent deux problèmes différents. Un champ `secret` range une
information d’authentification dans un magasin chiffré à côté du document ; le
document ne porte qu’un marqueur. Un champ `write_only` accepte une valeur, la
remet au script, puis la jette.

## Quand l’utiliser

Utilisez un champ `secret` pour une valeur que le système doit conserver : une
clé d’API, un haché de mot de passe, un token à usage unique. Utilisez un champ
`write_only` pour une valeur dont le script a besoin une seule fois et que
personne ne doit conserver, comme un mot de passe en clair que le script hache.

| | Champ `secret` | Champ `write_only` |
| --- | --- | --- |
| Valeur conservée | Oui, chiffrée, hors des documents | Non, jetée après l’écriture |
| Visible à la lecture | Non, un marqueur seulement | Non, disparue après l’écriture |
| Visible dans l’historique, la recherche, les exports | Non | Non |
| Visible des scripts | Non, le marqueur seulement | Oui, pendant l’écriture |
| Changement et effacement | Oui, depuis la page détail | Sans objet |

## Avant de commencer

- **Un domaine de brouillon.** Vous modifiez le doctype dans un domaine de
  brouillon.
- **Un mode.** Un champ `secret` déclare un `mode` : `hash` pour les valeurs
  qu’on ne fait que vérifier, `sealed` pour les valeurs que le système doit
  relire lui-même, et `token` pour une valeur à usage unique que Facet génère.
- **Les limites.** Les secrets n’apparaissent jamais comme arguments d’actions,
  dans des tableaux ou des dictionnaires, ni dans le nom d’affichage ni dans
  les modèles de recherche.

## Étapes

### 1. Déclarez le champ secret

```json
"api_key": {
  "type": "secret",
  "mode": "sealed",
  "title": "API key"
}
```

Règles par mode :

| Mode | Usage | Clé supplémentaire |
| --- | --- | --- |
| `hash` | Vérifie un candidat contre la valeur enregistrée, sans jamais la relire. | — |
| `sealed` | Le système relit la valeur pour ses propres fonctions. | — |
| `token` | Facet génère la valeur ; un appelant la consomme une fois. | `ttl_seconds` (obligatoire) |

`min`, `max` et `pattern` sont admis sur un champ secret ; ils portent sur le
texte en clair au moment où il est défini, pas sur le marqueur.

### 2. Définissez la valeur dans l’application

La page détail affiche un marqueur avec **Modifier** et **Effacer**. Une
modification dépose la nouvelle valeur : Facet la stocke et augmente la version
du marqueur. Un mode `token` affiche **Générer un nouveau jeton** et montre le
token une seule fois.

### 3. Déclarez un champ en écriture seule

```json
"new_password": {
  "type": "string",
  "write_only": true,
  "title": "New password"
}
```

Le script du doctype lit la valeur pendant l’écriture, fait son travail, puis
Facet retire le champ avant que le document ne soit stocké. Le duo habituel est
un champ `read_only` qui porte le haché : le script hache l’entrée en écriture
seule et y range le résultat, car un champ `secret` n’accepte que des valeurs
déposées.

## Exemple

```json
{
  "domain": "ops",
  "doctype": "Service",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "api_key": { "type": "secret", "mode": "sealed" },
    "reset_code": { "type": "secret", "mode": "token", "ttl_seconds": 3600 },
    "new_password": { "type": "string", "write_only": true }
  }
}
```

Un document stocké porte des marqueurs au lieu des valeurs :

```json
{
  "name": "Billing",
  "api_key": { "mode": "sealed", "version": 3, "set_at": "2026-03-01T09:12:00Z" }
}
```

Un secret effacé stocke `null`. Un champ `write_only` n’apparaît jamais dans le
contenu stocké.

## Dépannage

### L’écriture répond `422` sur le champ secret

Seules trois formes sont valides : un identifiant de dépôt, un marqueur, et
`null` pour effacer. Une chaîne en clair dans un corps de document est toujours
refusée.

### Le token a été affiché une fois et il est perdu

Les tokens s’affichent une seule fois, à la génération. Générez-en un nouveau ;
l’ancien cesse de fonctionner.

### Un administrateur ne peut pas relire la valeur

C’est voulu. Aucune route ne renvoie une valeur `sealed` ou hachée. Seules les
fonctions du système qui possèdent le champ la relisent, et une valeur hachée
n’est jamais lisible. Pour la renouveler, définissez une nouvelle valeur ; la
version du marqueur augmente.

Les valeurs résident dans le magasin chiffré, indexées par document et par nom
de champ, en dehors des tables de documents. Quand un document est supprimé, le
magasin garde ses emplacements jusqu’à ce que la fenêtre de rétention passe ;
une tâche de maintenance les retire ensuite.

### On a de nouveau besoin de la valeur en écriture seule

Elle n’existe plus. Facet ne la stocke jamais. Gardez la source de la valeur
hors de Facet si vous en aurez de nouveau besoin.

:::caution
Un retour arrière vers un état antérieur ne restaure pas les anciennes valeurs
secrètes. Les valeurs actuelles restent en place, et les anciennes informations
d’authentification ne reviennent jamais.
:::

## Voir aussi

- [Magasin de secrets (doc d’ingénierie)](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md) — le magasin, ses modes et son cycle de vie.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) — qui peut lire quels champs.
- [Actions nommées](/fr/build/model/behaviour/named-actions/) — ajoutez des opérations typées au doctype.
