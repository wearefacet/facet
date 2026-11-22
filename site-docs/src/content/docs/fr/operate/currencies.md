---
title: Devises et montants
description: Gérez la liste des devises et sachez comment les valeurs monétaires sont stockées, validées et filtrées.
audience: [operator, author]
features: [PLT-14, FE-15]
sidebar:
  order: 14
verified_at: 008dd880
---

Une devise est un document. Facet crée le registre lors de l’initialisation,
et vous le gérez dans l’espace Configurer comme n’importe quelle autre
liste. Un champ monétaire porte toujours une valeur et un ticker ensemble.
Le backend stocke les deux et vérifie le ticker à chaque écriture.

## Quand l’utiliser

Travaillez sur les devises quand :

- vous ajoutez ou retirez une devise du sélecteur,
- vous définissez un champ monétaire sur un doctype,
- vous filtrez des documents par montants.

## Avant de commencer

- Le domaine `core` est masqué dans la barre latérale de l’espace de
  travail. L’espace Configurer est le chemin d’accès.
- `facet seed:core` initialise les lignes de devises. La commande est
  idempotente : la relancer ne change rien.

## Étapes

### 1. Ouvrir la liste des devises

Ouvrez **Configurer → Devise**. La liste est un tableau standard avec les
routes habituelles de création et d’édition, `/core/Currency/new` et
`/core/Currency/{id}/edit`. L’aperçu et la page détail passent par les
modèles de vue pré-créés.

### 2. Ajouter ou modifier une devise

L’initialisation livre les devises ISO-4217 en circulation. Six lignes
démarrent actives — `CHF`, `CNY`, `EUR`, `GBP`, `JPY` et `USD` — et toutes
les autres lignes arrivent inactives. Une ligne porte ces champs :

| Champ | Signification | Exemple |
| --- | --- | --- |
| `ticker` | La clé du registre. Tout en majuscules, commence par une lettre, 3 à 10 caractères. Unique. | `EUR` |
| `symbol` | Le glyphe affiché. Facultatif — un symbole vide affiche le ticker seul. | `€` |
| `name` | Le nom anglais de la devise. | `Euro` |
| `digits` | Décimales de la sous-unité, de 0 à 4. Défaut `2`. | `2` |
| `active` | Met le ticker dans les flux de création quand `true`. | `true` |
| `favorite` | Épingle la ligne en haut du sélecteur de devises. | `false` |
| `grouping` | Groupement d’affichage : `standard` (milliers) ou `lakhs` (12,34,567). | `standard` |

Passez `active` à `false` pour retirer une devise sans la supprimer. Un
ticker inactif reste connu : les documents qui le portent continuent
de fonctionner.

### 3. Savoir comment le registre se propage

Chaque enregistrement d’une devise est diffusé à tous les processus en
cours, qui marquent leur registre en mémoire comme périmé. La prochaine
écriture sur chaque processus reconstruit le registre à partir des
documents. Après un redémarrage, le registre démarre périmé et s’hydrate à

la première écriture. Si une diffusion se perd, une limite de péremption —
`cache.staleness_ttl_s`, 300 secondes par défaut — force une reconstruction
à la prochaine lecture.

### 4. Suivre les règles d’écriture

Un contrôle vérifie les valeurs monétaires sur chaque chemin d’écriture :

| Chemin | Règle |
| --- | --- |
| Création | Chaque chemin monétaire doit nommer une devise enregistrée **et active**. Les chemins imbriqués comptent aussi. |
| Mise à jour | Seuls les tickers changés sont vérifiés. Réenregistrer un chemin avec son ticker existant passe même si la ligne est passée inactive. Un passage à un autre ticker exige une ligne active. |
| Import en masse | Le contrôle est sauté. Un ticker enregistré mais inactif s’importe. Un ticker supprimé échoue avec `UnknownCurrencyError`. |

Une violation répond `422` avec le code `inactive_currency` sur le champ
`<path>.currency`. Un ticker inconnu continue d’échouer comme erreur de
schéma.

### 5. Stocker et filtrer les valeurs monétaires

Une valeur monétaire est un objet JSON :

```json
{ "value": "123.42", "currency": "USD" }
```

`value` est une chaîne. Le backend l’interprète comme un décimal exact,
jamais comme un flottant, et la précision survit.

Un filtre monétaire accepte deux formes : `USD 1000` compare cette
seule devise, et un `1000` nu compare toutes les devises.

## Exemple

Créez une devise avec l’API, puis déclarez un champ monétaire qui
l’utilise :

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"ticker":"CRD","symbol":"Cr","name":"House credit","digits":2,"active":true,"favorite":false,"grouping":"standard"}' \
  "https://facet.localhost:3443/Api/core/Currency"
```

Le champ `ticker` est unique sur tout le doctype : un ticker déjà
porté par une ligne existante répond `422` avec une erreur de validation
`unique`.

La déclaration du champ dans le doctype :

```json
{
  "salary": { "type": "money", "currency": "USD" }
}
```

Le `currency` du champ est un indice d’affichage et une valeur par
défaut : une écriture qui omet le membre de devise est complétée avec
lui. La valeur stockée porte toujours son propre ticker. Filtrez le
doctype par montant :

```sh
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee?filters[salary__gte]=USD%201000"
```

## Dépannage

**Un enregistrement répond `422` avec `inactive_currency`.**

Le ticker est connu mais inactif. Activez la ligne de devise, ou gardez le
document sur son ticker existant — un réenregistrement avec le même ticker
passe.

**Le sélecteur n’affiche pas une devise.**

La ligne est inactive, ou le registre ne s’est pas encore reconstruit.
Activez la ligne et enregistrez un document ; la prochaine écriture
reconstruit le registre.

**Un import échoue sur une devise.**

Le ticker a été supprimé, pas seulement désactivé. Recréez la ligne de
devise avec le même ticker, puis relancez l’import.

**Le fichier de configuration ne contient aucune liste de devises.**

Les devises ne viennent pas de la configuration. Ce sont des documents
`core.Currency`, et le registre les lit dans la base de données.

## Voir aussi

- [Types de champs](/fr/build/field-types/) — le type de champ `money` sur
  un doctype.
- [Import/export en masse via l’API](/fr/apps/bulk-import-export/) — le
  chemin d’import qui ignore le contrôle de devise active.
- [Paramètres système](/fr/operate/system-settings/) — la couche
  d’exécution au-dessus du fichier de configuration.
- Internes sur GitHub :
  [util-money.md](https://github.com/wearefacet/facet/blob/main/doc/backend/util-money.md).
