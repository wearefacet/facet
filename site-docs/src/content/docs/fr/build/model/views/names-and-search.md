---
type: how-to
title: Libellés et texte de recherche
description: Écrivez les templates qui construisent le libellé de chaque document et son texte de recherche.
audience: [author]
features: [DOM-23]
sidebar:
  order: 0
verified_at: eee55a2
---

Chaque objet de Brightwater apparaît à trois endroits : une ligne de liste, le sélecteur quand quelqu’un lie un objet à un ticket, et la palette de recherche. Les trois affichent un seul libellé court pour le document. Facet construit ce libellé à partir d’un template `display_name` porté par le doctype, et les mots que la recherche compare à partir d’un template `search`. Tous deux sont des templates Jinja2. Cette page ne demande aucun code — seulement des expressions comme `{{ name }}`. Facet rend les deux à chaque écriture d’un document.

## Quand l’utiliser

- Un doctype affiche des ids bruts ou un libellé peu utile dans les listes et les sélecteurs.
- Les documents d’un doctype n’apparaissent jamais dans la recherche inter-doctypes.
- Le texte de recherche doit porter plus de mots que le libellé, par exemple un numéro de série ou une adresse e-mail.

## Avant de commencer

- **Droits de mise à jour** sur la définition du doctype.
- **Les noms de champs.** Les templates emploient les noms déclarés par le doctype.

## Écrire les templates

Ajoutez deux clés à la définition du doctype :

```yaml
# equipment.Item definition
display_name: "{{ name }}"
search: "{{ name }} {{ serial_number }}"
```

- `display_name` construit le libellé. Restez court : Facet coupe le résultat à 255 caractères.
- `search` construit le texte de recherche. Facet regroupe les suites d’espaces en une seule et coupe le résultat à 256 caractères. Le template de recherche peut aussi afficher `{{ display_name }}` — le libellé du même document. Un template `display_name` ne peut pas l’afficher : il lirait la valeur que la même écriture est en train de calculer.

Dans le Builder, vous modifiez les deux clés sur l’onglet **Général** du doctype, sous les templates de document. En fichiers, elles se trouvent dans le fichier YAML du doctype, à côté des champs.

## Variables et règles de rendu

| Variable | Contenu |
| --- | --- |
| `{{ field_name }}` | Un champ déclaré du doctype, par son nom. |
| `{{ address.city }}` | Un chemin dans un champ objet. |
| `{{ content.address.city }}` | L’arbre de contenu brut, pour des chemins avancés. |
| `{{ display_name }}` | Le libellé de ce document. Templates de recherche seulement. |

Le moteur est Jinja2. Les filtres courants fonctionnent ; celui dont vous avez le plus besoin est `join`, qui transforme un tableau en texte lisible. La liste complète des variables et des filtres se trouve dans le [Contexte des modèles Jinja2](/fr/reference/jinja2-context/).

| Type de valeur | Rendu |
| --- | --- |
| Champ référence | Le libellé stocké du document référencé. Une référence non résolue affiche le nom du doctype cible. Une référence de collection affiche sa première entrée. |
| Champ monétaire | La devise et le montant : `EUR 4800.00`. |
| Champ facultatif absent | Texte vide. Le rendu n’échoue jamais sur des données manquantes. |
| Champ tableau | Style Python : `['a', 'b']`. Passez par un filtre pour une sortie lisible. |

Deux limites mordent en pratique :

- **L’`id` du document n’est pas une variable.** `{{ id }}` fait échouer l’enregistrement. Brightwater contourne cela avec un champ déclaré : le code lisible de l’objet, `EQ-2026-0001`, est son `id` généré, et le numéro de série que l’équipe recherche se trouve dans `serial_number`. Déclarez un champ chaîne pour un code et affichez ce champ.
- **Une chaîne vide compte comme remplie.** `{% if nick %}` s’exécute pour `nick = ""`. Comparez avec `{{ nick == '' }}` quand la valeur vide doit compter comme vide.

## Exemple

Le doctype `equipment.Item` de Brightwater porte les deux clés montrées ci-dessus. Un objet stocké contient :

```json
{
  "name": "Main tent 10x15",
  "serial_number": "TN-10015-A",
  "status": "out"
}
```

Le libellé stocké est :

```text
Main tent 10x15
```

Le texte de recherche stocké est :

```text
Main tent 10x15 TN-10015-A
```

Le numéro de série se retrouve dans le texte de recherche mais pas dans le libellé : une recherche d’entrepôt pour `TN-10015` trouve l’objet tandis que chaque liste affiche toujours *Main tent 10x15*. Vérification en direct : le filtre de liste `filters[search]=TN-10015` retourne l’objet.

Si le template affichait `{{ tags }}` sur un doctype avec un champ tableau, le même document porterait `['vip', 'fleet']` dans son texte de recherche. Affichez plutôt `{{ tags | join(', ') }}`.

## Enregistrer, puis reprojeter les anciennes lignes

Enregistrez la définition. Les nouveaux documents rendent les templates aussitôt. Les documents écrits avant le changement gardent leur ancien libellé jusqu’à ce que Facet les reprojette. Lancez la commande de reprojection pour reconstruire le libellé et le texte de recherche de chaque document du domaine réel :

```sh
facet doctype:reproject equipment.Item
```

Voir [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/) pour savoir quand un changement de schéma exige cette étape.

## Sans template

Un doctype peut ne déclarer aucune des deux clés. L’outil de vérification rapporte alors ce que fait l’interface :

- **Sans `display_name`.** Les libellés retombent sur le premier champ non vide parmi `name`, `title` ou `label`, puis sur l’id brut du document.
- **Sans template `search`.** Le texte de recherche est le libellé regroupé. Le filtre `search` simple sur la route de liste le trouve encore, mais la recherche inter-doctypes ignore le doctype.
- **Aucune clé.** Une racine d’agrégat dans cet état est invisible de toute surface de recherche. La vérification émet une erreur, et Facet refuse de créer ou de publier le doctype. Un enfant possédé est exempté — on l’atteint par son parent, et la vérification rapporte une remarque d’information.

## Dépannage

**La vérification signale un template sans variable.**

Le template ne contient aucun `{{`. Il rend le même littéral pour chaque document — souvent une paire d’accolades perdue. Corrigez l’expression.

**Un enregistrement échoue avec une erreur de template.**

Le template compile mais échoue au rendu : un filtre mal orthographié, un type erroné ou une expression invalide. L’écriture est refusée ; rien n’est stocké. Corrigez le template et enregistrez de nouveau.

**Les listes affichent encore l’ancien libellé après un changement de template.**

Les lignes ont été écrites avant le changement. Lancez `facet doctype:reproject <domain.Doctype>`.

## Voir aussi

- [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) — chaque variable et chaque filtre.
- [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/) — les surfaces où le libellé apparaît.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — où vivent le libellé et le texte de recherche.
