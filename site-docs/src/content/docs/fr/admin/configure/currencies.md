---
title: Devises
description: Gérez le registre des devises et voyez comment les valeurs monétaires sont stockées, validées et filtrées.
type: how-to
audience: [operator, author]
features: [PLT-14, FE-15]
sidebar:
  order: 5
verified_at: eee55a2
---

Votre équipe enregistre des locations en euros, mais un fournisseur facture
en dollars. Une devise est un document. Facet pré-crée le registre, et vous
l’entretenez dans l’espace Configurer comme toute autre liste. Un champ
monétaire porte toujours une valeur et un ticker ensemble. Le backend stocke
les deux et vérifie le ticker à chaque écriture.

## Quand l’utiliser

Travaillez sur les devises quand :

- Vous ajoutez ou retirez une devise dans le sélecteur.
- Vous définissez un champ monétaire sur un doctype.
- Vous filtrez des documents par montants.

## Avant de commencer

- Le domaine `core` est caché dans la barre latérale de l’espace de
  travail. L’espace Configurer est l’entrée.
- [`facet seed:core`](/fr/reference/cli-facet/) pré-crée les lignes de
  devises. La commande est idempotente : la réexécuter ne change rien.

## Étapes

### 1. Ouvrez la liste des devises

Ouvrez **Configurer → Devise**. La liste est une table standard avec les
routes habituelles de création et d’édition, `/core/Currency/new` et
`/core/Currency/{id}/edit`. L’aperçu et la page détail se rendent par les
modèles de vue pré-créés.

### 2. Ajoutez ou modifiez une devise

L’initialisation livre les devises en circulation de la norme ISO-4217. Six
lignes démarrent actives — `CHF`, `CNY`, `EUR`, `GBP`, `JPY` et `USD` — et
toutes les autres lignes sont livrées inactives. `EUR` et `USD` sont
épinglées comme favorites. Une ligne porte ces champs :

| Champ | Signification | Exemple |
| --- | --- | --- |
| `ticker` | La clé du registre. Majuscules, commence par une lettre, 3 à 10 caractères. Unique. | `EUR` |
| `symbol` | Le glyphe d’affichage. Facultatif — un symbole vide affiche le ticker nu. | `€` |
| `name` | Le nom anglais de la devise. | `Euro` |
| `digits` | Chiffres de sous-unité, de 0 à 4. Valeur par défaut `2`. | `2` |
| `active` | Place le ticker dans les flux de création quand `true`. Une devise que vous créez à la main démarre active. | `true` |
| `favorite` | Épingle la ligne en tête du sélecteur de devises. | `false` |
| `grouping` | Groupement d’affichage : `standard` (milliers) ou `lakhs` (12,34,567). | `standard` |

Passez `active` à `false` pour retirer une devise sans la supprimer. Un
ticker inactif reste connu : les documents qui le portent continuent de
fonctionner.

### 3. Comprenez la propagation du registre

Chaque enregistrement de devise est diffusé et marque le registre en mémoire
comme périmé sur chaque processus en cours. La prochaine écriture de chaque
processus reconstruit le registre depuis les documents. Après un
redémarrage, le registre démarre périmé et s’hydrate à la première écriture.
Si une diffusion est perdue, une limite de péremption de
`cache.staleness_ttl_s`, 300 secondes par défaut, force une reconstruction à
la prochaine lecture.

### 4. Suivez les règles d’écriture

Un contrôle vérifie les valeurs monétaires sur chaque chemin d’écriture :

| Chemin | Règle |
| --- | --- |
| Création | Chaque chemin monétaire doit nommer une devise enregistrée **et active**. Les chemins imbriqués comptent aussi. |
| Mise à jour | Seuls les tickers modifiés sont vérifiés. Ré-enregistrer un chemin avec son ticker existant passe même si la ligne est passée inactive. Un changement vers un autre ticker exige une ligne active. |
| Import en masse | La vérification est ignorée. Un ticker enregistré mais inactif s’importe. Un ticker supprimé échoue avec `UnknownCurrencyError`. |

Une violation répond `422` avec le code `inactive_currency` sur le champ
`<path>.currency`. Un ticker inconnu continue d’échouer comme erreur de
schéma.

### 5. Stockez et filtrez les valeurs monétaires

Une valeur monétaire est un objet JSON :

```json
{ "value": "123.42", "currency": "USD" }
```

`value` est une chaîne. Le backend l’analyse comme un décimal exact, jamais
comme un flottant ; la précision survit.

Un filtre monétaire accepte deux formes : `USD 1000` compare cette seule
devise, et un `1000` nu compare toutes les devises. Un ticker non enregistré
dans un filtre est une faute de frappe de l’appelant ; il répond donc `422`
au lieu de ne rien trouver en silence.

## Exemple

Créez une devise avec l’API, puis déclarez un champ monétaire qui
l’utilise :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"ticker":"CRD","symbol":"Cr","name":"House credit","digits":2,"active":true,"favorite":false,"grouping":"standard"}' \
  "$(facet-cli host)/Api/core/Currency"
```

Le champ `ticker` est unique sur tout le doctype ; un ticker déjà porté par
une ligne réelle répond donc `422` avec une erreur de validation `unique`.

La déclaration du champ du doctype :

```json
{
  "salary": { "type": "money", "currency": "USD" }
}
```

Le `currency` au niveau du champ est un indice d’affichage et une valeur par
défaut : une écriture qui omet le membre currency est complétée avec lui. La
valeur stockée porte quand même son propre ticker. Filtrez le doctype par
montant :

```sh
curl -s -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/hr/Employee?filters[salary__gte]=USD%201000"
```

Sur l’exemple Brightwater, les deux formes de filtre se comportent
différemment. Les articles portent des prix d’achat en euros :

```text
GET /Api/equipment/Item?filters[purchase_price__gte]=USD 5000
→ {"data":[],"meta":{"count":0,"more":false}}     # aucun article n'existe en USD

GET /Api/equipment/Item?filters[purchase_price__gte]=1000
→ the tents at EUR 4800.00                        # un montant nu traverse les devises
```

## Dépannage

**Un enregistrement répond `422` avec `inactive_currency`.**

Le ticker est connu mais inactif. Activez la ligne de devise, ou laissez le
document sur son ticker existant — un ré-enregistrement avec le même ticker
passe.

**Le sélecteur ignore une devise.**

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

- [Types de champs](/fr/build/model/data/field-types/) — le type de champ
  `money` sur un doctype.
- [Import et export en masse](/fr/build/apps/data/bulk-import-export/) — le
  chemin d’import qui ignore la vérification d’activité.
- [Paramètres système](/fr/admin/configure/system-settings/) — l’étage
  d’exécution au-dessus du fichier de configuration.
- Internes sur GitHub : [util-money.md](https://github.com/wearefacet/facet/blob/main/doc/backend/util-money.md).
