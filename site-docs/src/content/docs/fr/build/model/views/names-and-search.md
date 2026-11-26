---
title: Nom d’affichage et texte de recherche
description: Écrivez les modèles Jinja2 qui construisent le nom d’affichage et le texte de recherche de chaque document.
audience: [author]
features: [DOM-23]
sidebar:
  order: 13
verified_at: fd345fe3
---

Une ligne de liste, une entrée de sélecteur et un résultat de recherche
exigent tous un nom court par document. Facet construit ce nom d’affichage
à partir d’un modèle `display_name` porté par le doctype. Le même doctype
peut porter un modèle `search`, qui construit les mots que la recherche
compare. Tous deux sont des modèles Jinja2 que Facet rend à chaque
écriture d’un document.

## Quand l’utiliser

- Un doctype affiche des ids bruts ou un nom peu utile dans les listes.
- Les documents d’un doctype n’apparaissent jamais dans la recherche
  inter-doctypes.
- Vous voulez que le texte de recherche porte plus de mots que le nom
  d’affichage, par exemple une adresse e-mail ou un code.

## Avant de commencer

- **Des droits de mise à jour.** Vous modifiez la définition du doctype.
  Il vous faut le droit de mise à jour sur ce doctype.
- **Les noms de champs.** Connaissez les noms de champs du doctype. Les
  modèles emploient ces noms.

## Étapes

### 1. Écrire le modèle du nom d’affichage

Ajoutez une clé `display_name` à la définition du doctype. La valeur est
un modèle Jinja2. Restez court : Facet coupe le résultat à 255 caractères.
Un doctype de personnes peut porter
`display_name: "{{ first_name }} {{ last_name }}"`.

### 2. Écrire le modèle du texte de recherche

Ajoutez une clé `search`. Facet regroupe les suites d’espaces en une seule
et coupe le résultat à 256 caractères. Le modèle de recherche peut aussi
afficher la variable réservée `display_name` — le nom d’affichage de ce
document.

### 3. Enregistrer et reprojeter les anciennes lignes

Enregistrez la définition. Facet applique les modèles aussitôt aux
nouveaux documents. Les documents écrits avant le changement gardent leur
ancien nom d’affichage jusqu’à ce que Facet les reprojette.

:::caution
Changer un modèle ne réécrit pas les lignes existantes. Lancez
`facet doctype:reproject <domain.Doctype>` pour reconstruire le nom
d’affichage et le texte de recherche de chaque document existant. Voir
[Faire évoluer un schéma](/fr/build/model/change-a-live-domain/).
:::

## Variables et filtres

| Variable | Contenu |
| --- | --- |
| `{{ field_name }}` | Un champ déclaré du doctype, par son nom. |
| `{{ address.city }}` | Un chemin dans un champ objet. |
| `{{ content.address.city }}` | L’arborescence brute du contenu, pour des chemins avancés. |
| `{{ display_name }}` | Le nom d’affichage de ce document. Modèles de recherche seulement. |

Les modèles sont rendus par un moteur Jinja2. Les filtres courants
fonctionnent ; celui dont vous avez le plus besoin est `join`, qui
transforme un tableau en texte lisible. Voir la
[Référence du contexte Jinja2](/fr/reference/jinja2-context/).

Règles de rendu :

| Type de valeur | Rendu |
| --- | --- |
| Champ référence | Le nom d’affichage enregistré du document référencé. Une référence non résolue affiche le nom du doctype cible. Une référence de collection affiche sa première entrée. |
| Champ monétaire | La devise et le montant : `USD 120000`. |
| Champ facultatif absent | Texte vide. Le rendu n’échoue jamais sur des données manquantes. |
| Champ tableau | Style Python : `['a', 'b']`. Passez par un filtre pour une sortie lisible. |

Deux limites surprennent en pratique :

- **L’`id` du document n’est pas une variable.** `{{ id }}` fait échouer
  l’enregistrement. Déclarez un champ chaîne pour un code lisible par un
  humain et affichez ce champ.
- **Une chaîne vide compte comme remplie.** `{% if nick %}` s’exécute pour
  `nick = ""`. Comparez avec `{{ nick == '' }}` quand la valeur vide doit
  compter comme vide.

## Exemple

Un doctype `hr.Person` déclare les champs `first_name`, `last_name`,
`email`, `tags` (tableau de chaînes) et `manager_id` (référence à

`hr.Person`). La définition porte :

```yaml
display_name: "{{ first_name }} {{ last_name }}"
search: "{{ first_name }} {{ last_name }} {{ email }} {{ tags | join(', ') }}"
```

Un document contient :

```json
{
  "first_name": "Ada",
  "last_name": "Lovelace",
  "email": "ada@facet.local",
  "tags": ["crm", "vip"],
  "manager_id": "hr.Person.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

Le nom d’affichage enregistré est :

```text
Ada Lovelace
```

Le texte de recherche enregistré est :

```text
Ada Lovelace ada@facet.local crm, vip
```

Si le modèle affichait `{{ tags }}` sans le filtre, le même document
porterait `['crm', 'vip']` dans son texte de recherche.

## Le comportement sans modèle

Un doctype peut ne déclarer aucune des deux clés. L’outil de vérification
signale alors ce que fait l’interface :

- **Sans `display_name`.** Les noms d’affichage retombent sur le premier
  des champs `name`, `title` ou `label`, puis sur l’id brut du document.
- **Sans modèle `search`.** Le texte de recherche est le nom d’affichage
  regroupé. Un terme de recherche le trouve encore ; la recherche
  inter-doctypes ignore le doctype.
- **Aucune clé.** Un terme de recherche ne trouve que l’id du document,
  et la vérification émet un avertissement. Déclarez au moins une clé.

## Dépannage

**La vérification signale un modèle sans variable.**

Le modèle ne contient aucun `{{`. Il rend le même littéral pour chaque
document — souvent une paire d’accolades perdue. Corrigez l’expression.

**Un enregistrement échoue avec une erreur de modèle.**

Le modèle compile mais échoue au rendu : un filtre mal orthographié, un
type erroné ou une expression invalide. L’écriture est refusée ; rien
n’est stocké. Corrigez le modèle et enregistrez de nouveau.

**Les listes affichent encore l’ancien nom après un changement de
modèle.**

Les lignes ont été écrites avant le changement. Lancez
`facet doctype:reproject <domain.Doctype>`.

## Voir aussi

- [Référence du contexte Jinja2](/fr/reference/jinja2-context/) — chaque
  variable et chaque filtre.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) —
  où se trouvent le nom d’affichage et le texte de recherche.
- [Modèles de vue](/fr/build/model/views/document-pages/) — afficher les mêmes champs
  sur la page détail.
