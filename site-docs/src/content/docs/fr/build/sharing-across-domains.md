---
title: Partager des données entre domaines
description: Laissez un domaine lire les champs d’un autre grâce aux attributions et aux copies répliquées.
audience: [author, admin]
features: [DOM-14, DOM-25]
sidebar:
  order: 20
verified_at: fd345fe3
---

Les domaines gardent leurs données séparées. Deux outils ouvrent une porte
contrôlée entre eux. Une **attribution de domaine** est un contrat de
consentement : le domaine producteur nomme un consommateur et les ressources
que celui-ci peut lire. Un **champ répliqué** copie une valeur d’un document
source dans le document du consommateur, qui l’affiche sans aller-retour.

## Quand l’utiliser

- Un doctype référence des documents d’un autre domaine et ses scripts doivent
  les lire.
- Une liste du domaine `hr` doit afficher une valeur qui se trouve dans le
  domaine `identity`, comme le nom complet d’une personne.
- Vous voulez que la copie suive la source automatiquement.

## Avant de commencer

- **Deux côtés.** Décidez quel côté porte le contrat : le **producteur**
  fournit les données, le **consommateur** les reçoit.
- **Étiquettes.** Étiquetez les champs du producteur que vous partagez. Un
  champ sans étiquette porte l’étiquette implicite `default`.
- **Lecture seule.** Les attributions donnent un accès en lecture seulement.
  Aucune attribution n’autorise jamais une écriture.

## Étapes

### 1. Déposez l’attribution chez le producteur

Créez un document d’attribution sous le domaine **producteur**, comme enfant de
son document de domaine. Une attribution par consommateur :

```json
{
  "consumer_domain": "core.Domain.bill",
  "resources": [
    { "doctype": "identity.Person", "tags": ["default"] }
  ]
}
```

`resources` compte une entrée par doctype producteur que le consommateur peut
lire. Les étiquettes servent de masque de champs, à l’échelle de l’étiquette :
un champ est couvert dès qu’il partage au moins une étiquette avec l’entrée.

### 2. Activez l’attribution

Une nouvelle attribution démarre inactive. Un détenteur de l’action `activate`
sur les attributions du domaine producteur l’active ; le même droit la
désactive. Facet refuse l’auto-attribution : un domaine n’a besoin d’aucun
contrat pour se lire lui-même.

:::note
Une attribution inactive n’ouvre rien. La désactivation n’efface pas les
valeurs déjà copiées.
:::

### 3. Déclarez le champ répliqué chez le consommateur

Sur le doctype consommateur, ajoutez deux champs : une référence vers le
doctype source, et un champ qui porte la copie :

```yaml
fields:
  person:
    type: reference
    doctype: "identity.Person"
  person_full_name:
    type: string
    replicate:
      via: person
      field: full_name
    on_source_delete: unset
```

Règles du couple :

- `via` nomme le champ de référence sur le même doctype.
- Le champ source ne doit pas être un secret, et une copie ne peut pas
  alimenter une autre copie.
- `on_source_delete` vaut `keep` (défaut) ou `unset`. `keep` conserve la valeur
  copiée ; `unset` l’efface quand la source est supprimée.
- Les utilisateurs ne peuvent pas écrire un champ copié. Il ne peut être ni
  obligatoire ni unique.

### 4. Observez le comportement des copies

Facet tire la valeur initiale à la création d’un document consommateur ou au
changement de sa référence. Les changements ultérieurs de la source poussent
vers chaque consommateur qui la référence. Chaque poussée est une vraie mise à

jour, auditée, du document consommateur.

:::caution
Une liaison inter-domaines sans attribution active reste inerte. Le contrôle
signale l’attribution manquante, et la copie reste vide tant que le producteur
n’a pas activé le contrat.
:::

## Exemple

Le domaine `bill` facture des personnes enregistrées dans le domaine
`identity`. Le producteur dépose puis active une attribution sur
`identity.Person` avec l’étiquette `default`. Le doctype `bill.Invoice` porte :

```yaml
fields:
  person:
    type: reference
    doctype: "identity.Person"
  person_full_name:
    type: string
    replicate:
      via: person
      field: full_name
```

Une facture référence `identity.Person.01HXYZ7Q2K4N82GVG2J7K4MHZZ`, dont le
`full_name` vaut `Ada Lovelace`. À la création, `person_full_name` se remplit
avec `Ada Lovelace`. La personne se renomme plus tard en `Ada King`. La copie
sur la facture passe à `Ada King` sans que personne ne touche à la facture.
L’historique montre la mise à jour comme un changement automatisé sur la
facture.

## Dépannage

**La copie reste vide.**

Suivez la chaîne : l’attribution doit être active, elle doit nommer le doctype
source, et ses étiquettes doivent couvrir le champ source. Le contrôle du
doctype nomme la pièce manquante.

**La copie n’a pas suivi un changement de la source.**

La référence doit pointer vers le document source. Une référence vide ou
orpheline n’a aucune source d’où tirer.

**L’attribution a disparu de la vue du consommateur.**

Une attribution élargie repasse à l’état inactif jusqu’à ce que le producteur
l’accepte à nouveau. La fenêtre de publication le signale quand cela arrive.

## Voir aussi

- [Doc des attributions de domaine](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md) — le contrat d’attribution et ses contrôles.
- [Réplication entre domaines](/fr/concepts/cross-domain-replication/) — comment les copies circulent entre les domaines.
- [Hooks d’événements](/fr/build/event-hooks/) — réagissez aux événements d’un autre domaine, dans la limite de l’attribution.
