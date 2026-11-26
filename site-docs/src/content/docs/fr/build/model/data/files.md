---
title: Fichiers et artifacts dans les champs
description: Stockez des fichiers dans des champs via le magasin d’artifacts et contrôlez les types de fichiers qu’un champ accepte.
audience: [author]
features: [PLT-04]
sidebar:
  order: 8
verified_at: fd345fe3
---

Un champ `file` contient un fichier, pas une chaîne de caractères. Le champ stocke l’id d’un artifact, et le magasin d’artifacts garde les octets en dehors du document. Les documents restent ainsi petits, et deux documents peuvent partager un même fichier sans le copier.

## Quand l’utiliser

Choisissez un champ `file` quand le fichier fait partie de l’enregistrement : un contrat signé sur une affaire, un CV sur un candidat, une photo sur un article. Pour les fichiers d’échange qui ne se rattachent à aucun champ, passez par le panneau des pièces jointes (voir [Sidecars (commentaires, pièces jointes)](/fr/build/model/relations/comments-attachments/)).

## Avant de commencer

- **Le stockage est intégré.** Le magasin d’artifacts existe sur chaque instance. Vous déclarez le champ ; vous ne configurez pas le stockage.
- **Une limite de taille.** Un envoi est limité à 50 mégaoctets par défaut. Votre administrateur règle cette limite.
- **Une liste de types, si vous en voulez une.** Facet accepte tout type de fichier par défaut. Déclarez une liste `accept` quand le champ ne doit recevoir que certains types.

## Étapes

### 1. Déclarez le champ fichier

```json
"contract": {
  "type": "file",
  "accept": ["application/pdf"],
  "title": "Signed contract"
}
```

La liste `accept` emploie des types MIME. Facet détermine le type d’un envoi d’après le contenu du fichier, pas d’après son nom, et refuse tout envoi qui ne correspond pas à la liste. Un champ sans `accept` accepte tous les types.

### 2. Téléversez un fichier dans l’application

Dans un formulaire, l’utilisateur choisit un fichier pour le champ. Facet téléverse les octets, les stocke, puis place l’id de l’artifact dans le champ. Enregistrement et téléversement ne font qu’un : si l’un échoue, rien n’est écrit.

### 3. Téléversez via l’API

Envoyez un corps multipart. Une partie nommée `$content` porte les champs du document, et une partie par champ fichier porte les octets, nommée d’après le champ.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Deliverable" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -F '$content={"title":"Kickoff deck"}' \
  -F 'contract=@./kickoff.pdf'
```

`-k` ignore la vérification du certificat de l’adresse de développement local.

### 4. Sachez ce que fait le magasin

| Règle | Effet |
| --- | --- |
| Contenu identique, une seule copie | Des octets identiques sont stockés une fois, puis réutilisés. |
| L’accès suit les documents | Un fichier se lit à travers les documents qui le référencent. |
| Envois hors flux | Un fichier collé dans un texte long est d’abord téléversé, puis lié lors de l’enregistrement. |

Un champ `longtext` peut embarquer un lien de fichier de la forme `urn:facet:artifact:<id>`. Chaque lecteur du document obtient l’accès au fichier.

## Exemple

```json
{
  "domain": "projects",
  "doctype": "Deliverable",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ title }}",
  "fields": {
    "title": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "contract": { "type": "file", "accept": ["application/pdf"] },
    "deck": { "type": "file" }
  }
}
```

Le champ `contract` n’accepte que des fichiers PDF. Le champ `deck` accepte tout type de fichier.

## Dépannage

### Le téléversement répond `413`

Le fichier dépasse la limite de taille. Prenez un fichier plus petit, ou demandez à votre administrateur d’augmenter la limite.

### Le téléversement répond `422` avec une erreur MIME

Le contenu du fichier ne correspond pas à la liste `accept`. Ajustez la liste du champ ou convertissez le fichier ; changer seulement le nom du fichier ne sert à rien, car Facet lit le contenu.

### Un export contient un id court au lieu du fichier

C’est l’id de l’artifact. Le contenu du fichier ne voyage pas avec un export CSV ou JSON ; téléchargez les fichiers depuis la page détail du document.

### Un lien de fichier dans un document paraît mort

Un administrateur a détruit le fichier. La référence reste dans le texte, mais les octets ont disparu.

## Voir aussi

- [Artifacts (doc d’ingénierie)](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md) — le magasin d’artifacts en détail.
- [Domaines et isolement](/fr/discover/how-it-works/domains/) — le magasin se situe en dehors de votre domaine.
- [Champs `secret` et en écriture seule](/fr/build/model/data/secret-fields/) — rangez des identifiants en sécurité dans des champs.
