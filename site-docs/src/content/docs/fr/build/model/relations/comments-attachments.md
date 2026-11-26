---
title: Sidecars (commentaires, pièces jointes)
description: Attachez des panneaux de commentaires et de pièces jointes à un doctype, et contrôlez qui peut les utiliser.
audience: [author]
features: [DOM-06]
sidebar:
  order: 7
verified_at: fd345fe3
---

Un sidecar est un panneau affiché à côté d’un document : les commentaires
sur un onglet, les fichiers sur un autre. Les enregistrements sont stockés
dans leurs propres doctypes du domaine `core`, et le doctype hôte déclare les
panneaux qu’il porte. Une seule déclaration sert tous les doctypes qui
veulent le panneau : vous ne copiez jamais la logique de commentaires dans
votre domaine.

## Quand l’utiliser

Ajoutez le panneau `comments` quand un enregistrement fait l’objet de
discussions. Ajoutez le panneau `attachments` quand des fichiers accompagnent
un enregistrement. Les deux panneaux se déclarent sur le doctype : vous
pouvez donc les donner à n’importe quel doctype de votre domaine.

## Avant de commencer

- **Un domaine de brouillon.** Vous modifiez le doctype hôte dans un domaine
  de brouillon. Voir [Concevoir des doctypes](/fr/build/model/data/design-doctypes/).
- **Rien à créer.** Les doctypes sidecar `core.Comment` et `core.Attachment`
  existent sur chaque instance. Vous les déclarez sur votre hôte ; vous ne
  les créez pas.
- **Un nom de segment disponible.** Un nom de segment (le segment de route du
  panneau, comme `comments`) ne peut pas entrer en collision avec une relation
  `children` du même nom.

## Étapes

### 1. Ajouter le bloc `sidecars` au doctype hôte

Chaque entrée décrit un panneau : la clé est le segment de route, et la
valeur désigne le doctype sidecar et la colonne de référence qui pointe vers
l’hôte.

```json
"sidecars": {
  "comments": { "doctype": "core.Comment", "column": "target" },
  "attachments": { "doctype": "core.Attachment", "column": "target" }
}
```

Deux clés facultatives affinent le panneau : `label` change le texte de
l’onglet — `"Notes"` au lieu de « Comments » — et `order` règle l’ordre des
onglets quand l’ordre alphabétique par défaut ne convient pas.

### 2. Vérifier les droits

Une attribution sidecar imbriquée suit le chemin de l’hôte. En pratique :

| Droit de l’appelant | Ce qu’il permet |
| --- | --- |
| read sur `hr.Employee` | Lire les commentaires et les pièces jointes. |
| create sur `hr.Employee` | Écrire des commentaires et joindre des fichiers. |
| create sur `hr.Employee.Comment` | Commenter en tant qu’utilisateur en lecture seule. |

C’est ainsi que vous permettez à un utilisateur en lecture seule de
commenter : ses droits sur l’hôte restent en lecture seule, et vous ajoutez
la ligne imbriquée explicite pour l’action.

### 3. Voir le panneau

Ouvrez un document. Le panneau se place à côté de la page et affiche un
onglet par sidecar déclaré, avec un compteur par onglet. Les commentaires
acceptent le markdown, gèrent les réponses et notifient une personne quand
vous la mentionnez. Les pièces jointes affichent le type, la taille, la
personne qui a déposé le fichier, et l’heure.

## Exemple

La définition ci-dessous donne les deux panneaux à un enregistrement employé,
avec l’onglet des commentaires renommé.

```json
{
  "domain": "hr",
  "doctype": "Employee",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "job_title": { "type": "string", "required": true }
  },
  "sidecars": {
    "comments": { "doctype": "core.Comment", "column": "target", "label": "Notes" },
    "attachments": { "doctype": "core.Attachment", "column": "target" }
  }
}
```

L’API crée un commentaire via le chemin de l’hôte :

```sh
curl -k -X POST "https://facet.localhost:3443/Api/hr/Employee/01HQ2F5WX8K4M3PZC6NRB9TJVA/comments" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"body": "Welcome aboard"}'
```

`-k` évite la vérification du certificat de l’adresse de développement
locale. Facet déduit le `target` du chemin. Une clé `target` dans le corps
répond `400`.

## Dépannage

### Le panneau ne s’affiche pas

Le doctype ne porte pas de bloc `sidecars`, ou le doctype a été modifié après
l’ouverture de la page. Vérifiez la définition et rechargez.

### Commenter répond `403`

Votre rôle peut lire l’hôte, mais il ne porte ni droit `create` sur le chemin
de l’hôte ni ligne imbriquée explicite. Demandez à l’auteur du domaine un
droit `create` sur l’hôte, ou la ligne imbriquée montrée à l’étape 2.

### Une création directe de `core.Comment` répond `422`

Les enregistrements sidecar se créent par le document hôte, jamais par la
route directe. Utilisez le chemin imbriqué montré dans l’exemple.

### Les commentaires disparaissent après un delete

Facet supprime les enregistrements sidecar quand leur hôte est supprimé.
Cette suppression est séparée de celle de l’hôte : elle n’est pas annulée
quand le document hôte lui-même est restauré.

## Voir aussi

- [Doctypes sidecar (doc d’ingénierie)](https://github.com/wearefacet/facet/blob/main/doc/backend/sidecar.md) — le contrat sidecar complet.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) — les deux barrières que franchit chaque action de panneau.
- [Fichiers et artifacts dans les champs](/fr/build/model/data/files/) — stockez des fichiers dans les champs, pas seulement dans le panneau.
