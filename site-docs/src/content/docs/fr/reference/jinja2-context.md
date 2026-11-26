---
type: reference
title: Contexte des modèles Jinja2
description: Variables et filtres disponibles dans les modèles Jinja2.
audience: [author, developer]
features: [DOM-22, DOM-23]
sidebar:
  order: 13
verified_at: 008dd880
---

Utilisez cette page pour écrire un modèle et vérifier les variables et les
filtres à votre disposition.

Facet rend des modèles Jinja2 à trois endroits : l’étiquette `display_name`
et le texte `search` d’un doctype, tous deux sur le serveur, et, dans le
navigateur, le titre des puces du calendrier d’une vue collection.

Cette page décrit les variables liées par chaque modèle et les filtres
enregistrés par le moteur serveur.

## Où s’exécutent les modèles

| Modèle | Déclaré dans | Rendu | Moteur |
| --- | --- | --- | --- |
| `display_name` | La définition du doctype | Sur le serveur, à chaque écriture de document. Le résultat est l’étiquette du document, tronquée à 255 caractères. | Sous-ensemble Jinja2 complet (Crinja), filtres inclus |
| `search` | La définition du doctype | Sur le serveur, à chaque écriture de document. Le résultat est le texte de recherche : espaces normalisés, accents retirés, tronqué à 256 caractères. | Sous-ensemble Jinja2 complet (Crinja), filtres inclus |
| `config.calendar.title_template` | Un document `core.CollectionView` | Dans le navigateur, pour chaque puce du calendrier. | Sous-ensemble minimal : uniquement les placeholders `{{ path }}` |

Une écriture qui rend un modèle serveur cassé échoue et est annulée. Un
champ absent n’échoue jamais — le rendu est vide.

## Variables de contexte — modèles serveur

| Nom | Type | Contenu |
| --- | --- | --- |
| `<field_name>` | Le type du champ | Une variable par champ déclaré, liée à la valeur du champ après l’écriture. Les chemins à points descendent dans les champs objet : `{{ address.postal_code }}`. |
| `content` | object | L’arbre de contenu brut du document, pour les chemins que les champs déclarés ne décrivent pas : `{{ content.address.postal_code }}`. |
| `display_name` | string | L’étiquette du document. Liée dans les modèles `search` uniquement. Un modèle `display_name` ne doit pas la référencer — l’enregistrement refuse l’auto-référence. |

Règles que le validateur impose à l’enregistrement :

- Toute variable racine doit être un champ déclaré ou une variable
  réservée. `{{ id }}` est refusé — l’id du document n’est pas une
  variable. Déclarez un champ de type string pour un code lisible par un
  humain et affichez ce champ.
- Les variables utilisées uniquement dans les arguments de `{% if %}` ou
  `{% for %}` ne sont pas validées.

### Rendu des valeurs

| Type de valeur | Rendu |
| --- | --- |
| Champ référence | L’étiquette stockée du document référencé. Une référence non résolue affiche le nom seul du doctype cible, jamais l’id. Une référence collection affiche sa première entrée. |
| Champ money | La devise et le montant : `USD 120000`. Les objets money imbriqués se formatent de la même façon. |
| Champ absent | Texte vide. Un chemin imbriqué sur un champ absent produit aussi un rendu vide. |
| Tableau | Style Python : `['a', 'b']`. Utilisez `join` pour une sortie lisible. |
| Objet affiché comme feuille | Texte vide. |
| HTML ou guillemets | Tel quel. L’autoescape est désactivé ; les modèles produisent du texte brut. |

Deux particularités comptent en pratique :

- **Une chaîne vide est truthy.** `{% if nick %}` s’exécute pour
  `nick = ""`. Comparez avec `{{ nick == '' }}` quand la valeur vide doit
  faire échouer le test.
- **Une fonction globale masque un champ.** Un nom tel que `range` cache
  un champ du même nom.

## Filtres enregistrés

Le moteur serveur enregistre ces filtres. Les arguments sont des arguments
nommés, par exemple `{{ tags | join(', ') }}` ou `{{ price | round(2) }}`.

| Filtre | Arguments | Effet |
| --- | --- | --- |
| `abs` | — | Valeur absolue d’un nombre. |
| `append` | `string` | Ajoute la chaîne après la valeur. |
| `attr` | `name` | Lit l’attribut `name` d’un objet. |
| `batch` | `linecount`, `fill_with` | Découpe un tableau en lignes de `linecount` éléments. |
| `capitalize` | — | Met la première lettre en majuscule, le reste en minuscules. |
| `center` | `width` | Complète la valeur avec des espaces jusqu’à `width`. |
| `count` | — | Alias de `length`. |
| `d` | — | Alias de `default`. |
| `date` | `format` | Formate une valeur temporelle avec le motif donné. Les valeurs de champ sont des chaînes ; ce filtre s’applique donc rarement à elles. |
| `default` | `default_value`, `boolean` | Retourne `default_value` quand la valeur est vide. Avec `boolean=true`, aussi quand elle est falsy. |
| `dictsort` | `case_sensitive`, `by` | Trie un dictionnaire par clé (`by="key"`, la valeur par défaut) ou par valeur. |
| `e` | — | Alias de `escape`. |
| `escape` | — | Échappe la valeur en HTML. L’autoescape est désactivé ; réservez-le aux sorties HTML voulues. |
| `filesizeformat` | `binary` | Formate un nombre d’octets en `1.5 kB` ou, avec `binary=true`, `1.5 KiB`. |
| `first` | — | Premier élément d’un tableau. |
| `float` | `default` | Convertit en float ; `default` quand la valeur n’est pas un nombre. |
| `forceescape` | — | Échappe la valeur en HTML, même dans une chaîne marquée sûre. |
| `format` | — | Formatage à la `sprintf` : `{{ "%d items" | format(3) }}`. |
| `groupby` | `attribute` | Regroupe un tableau par attribut. |
| `indent` | `width`, `indentfirst` | Indente chaque ligne de `width` espaces. |
| `int` | `default`, `base` | Convertit en entier ; `default` quand la valeur n’est pas un nombre. |
| `join` | `separator`, `attribute` | Joint un tableau en une seule chaîne. Le filtre dont la plupart des modèles ont besoin. |
| `last` | — | Dernier élément d’un tableau. |
| `length` | — | Nombre d’éléments d’un tableau ou d’une chaîne. |
| `list` | — | Convertit la valeur en tableau. |
| `lower` | — | Met la valeur en minuscules. |
| `map` | `attribute`, ou un nom de filtre | Prend un attribut de chaque élément, ou applique un filtre à chaque élément. |
| `pprint` | `verbose` | Affiche la valeur de façon lisible pour le débogage. |
| `prepend` | `string` | Place la chaîne avant la valeur. |
| `random` | — | Un élément au hasard d’un tableau. |
| `reject` | — | Garde les éléments qu’un test rejette. |
| `rejectattr` | — | Garde les éléments dont un test rejette l’attribut. |
| `replace` | `old`, `new`, `count` | Remplace les occurrences de `old` par `new`. |
| `reverse` | — | Inverse un tableau ou une chaîne. |
| `round` | `precision`, `method`, `base` | Arrondit un nombre à `precision` chiffres. |
| `safe` | — | Marque la valeur comme à ne pas échapper. |
| `select` | — | Garde les éléments qu’un test accepte. |
| `selectattr` | — | Garde les éléments dont un test accepte l’attribut. |
| `slice` | `slices`, `fill_with` | Découpe un tableau en `slices` parts à peu près égales. |
| `sort` | `reverse`, `case_sensitive`, `attribute` | Trie un tableau, éventuellement par un attribut. |
| `striptags` | — | Retire les balises HTML et réduit les espaces. |
| `sum` | `attribute`, `start` | Additionne les éléments, ou leur `attribute`. |
| `title` | — | Met chaque mot en majuscule initiale. |
| `tojson` | `indent` | Sérialise la valeur en JSON. |
| `trim` | — | Retire les espaces aux deux extrémités. |
| `truncate` | `length`, `killwords`, `end`, `leeway` | Coupe la chaîne à `length` et ajoute `end`. |
| `upper` | — | Met la valeur en majuscules. |
| `urlencode` | — | Encode la valeur pour une URL. |
| `urlize` | `trim_url_limit`, `nofollow`, `target`, `rel` | Transforme les URL du texte en liens. |
| `wordcount` | — | Compte les mots. |
| `wordwrap` | `width`, `break_long_words`, `wrapstring` | Insère des retours à la ligne tous les `width` caractères. |
| `xmlattr` | `autoescape` | Sérialise un dictionnaire en attributs HTML. |

Un filtre absent ou inconnu lève une erreur au rendu. L’écriture qui a
déclenché le rendu est refusée.

## Variables de contexte — modèle de titre du calendrier

Le `title_template` du calendrier se rend dans le navigateur sous un
ensemble de règles plus restreint :

| Nom | Contenu |
| --- | --- |
| `<field_name>` | Un champ déclaré du doctype parent. |
| `content` | L’arbre de contenu brut du document, via le préfixe `content.`. |
| `created_at`, `updated_at` | Les timestamps système du document. |

`display_name` est refusé dans ce modèle — en l’absence de modèle, la puce
s’appuie dessus. Le moteur de rendu du navigateur ne connaît que les
placeholders :

- Les filtres, les blocs `{% if %}` et les commentaires `{# #}` se rendent
  tels quels, sans erreur.
- Un champ absent se rend vide.
- Un objet money se rend en `EUR 100`.
- Un tableau se rend avec les éléments joints par `, `.

La validation à l’enregistrement vérifie toujours la syntaxe et chaque
variable racine ; un modèle qui ne pourrait jamais se rendre est refusé
dès la rédaction.

## Exemple complet

Un doctype `hr.Person` déclare les champs `first_name`, `last_name`,
`email`, `tags` (tableau de string), `salary` (money) et `manager_id`
(référence à `hr.Person`). La définition porte :

```yaml
display_name: "{{ last_name | upper }}, {{ first_name }} — {{ salary }}"
search: "{{ first_name }} {{ last_name }} {{ email }} {{ tags | join(', ') }}"
```

Un document stocke :

```json
{
  "first_name": "Ada",
  "last_name": "Lovelace",
  "email": "ada@facet.local",
  "tags": ["crm", "vip"],
  "salary": { "value": "120000", "currency": "USD" },
  "manager_id": "hr.Person.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

L’étiquette stockée est :

```text
LOVELACE, Ada — USD 120000
```

Le texte de recherche stocké est :

```text
Ada Lovelace ada@facet.local crm, vip
```

La variable `{{ manager_id }}` afficherait l’étiquette stockée de la
personne référencée ; les deux modèles ci-dessus ne l’utilisent pas.

## Voir aussi

- [Noms d’affichage et texte de recherche (Jinja2)](/fr/build/model/views/names-and-search/) — écrire les deux modèles du doctype.
- [Modèles de vue](/fr/build/model/views/document-pages/) — les modèles de vue structurés, un format séparé.
- [Champs calculés](/fr/build/model/data/computed-fields/) — des fonctions Lua, pas des modèles.
