---
title: Vérifier un domaine avant publication
description: Lancez l’outil de vérification sur un domaine de brouillon et traitez ses anomalies avant de publier.
audience: [author]
features: [DOM-16]
sidebar:
  order: 18
verified_at: fd345fe3
---

Un domaine de brouillon embarque un outil de vérification. Il lit chaque
doctype du domaine et rapporte ce qui ne fonctionnerait pas après la
publication. Lancez-le à chaque édition. La publication revérifie ensuite les
règles qui impliquent des domaines réels, et la fenêtre de publication affiche
le résultat avant toute écriture.

## Quand l’utiliser

- Avant de publier un brouillon.
- Après avoir ajouté une référence, un champ de réplication ou un modèle de vue.
- Quand la page d’accueil du Builder affiche un compteur d’anomalies sur une carte de brouillon.

## Avant de commencer

- **Un domaine de brouillon** dont vous détenez le droit de mise à jour.
- **Rien à perdre.** La vérification est en lecture seule. Elle n’écrit rien.

## Étapes

### 1. Lancer la vérification

Ouvrez le brouillon dans le Builder et ouvrez l’onglet **Vérification**. La
page d’accueil affiche aussi un compteur d’anomalies sur chaque carte de
brouillon. Depuis un terminal, la vérification tient en une seule lecture du
domaineà :

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/core/Domain/_a1b2c3/check"
```

### 2. Lire les anomalies et les remarques

Le rapport se répartit en deux sortes d’entréesà :

| Type | Signification |
| --- | --- |
| Anomalie (avertissement ou erreur) | Un vrai défaut. La confirmation de publication les compte. |
| Remarque (info) | Un repli voulu, pas une faute. Par exemple, un type de vue manquant, ou l’absence de modèle `display_name`. |

Un défaut bloque aussi les écritures, et pas seulement le rapportà : un champ
référence déclaré avec un nom non qualifié, tel que `Client` (sans préfixe
`domain.`), rejette toute valeur de ce champ. La vérification le marque comme
une erreur.

### 3. Corriger et relancer

Chaque anomalie nomme une catégorie et souvent un champà :

| Catégorie | Concerne |
| --- | --- |
| `reference` | Un doctype cible non enregistré, ou un nom de cible non qualifié. |
| `children` | Un doctype enfant non enregistré dans le domaine. |
| `composition` | Un lien parent/enfant à sens unique, un `aggregate_root` manquant, ou un enfant modélisé comme référence. |
| `replication` | Un champ de réplication dont la source, le type ou l’attribution ne tient pas. |
| `view` | Un modèle de vue cassé, ou un modèle lié à un champ inconnu. |
| `template` | Un modèle de libellé ou de recherche sans aucune variable. |
| `actions` | Des actions nommées sans script. |
| `hooks` | Un hook de domaine qui ne compile pas. |

Corrigez la définition dans l’éditeur, puis relancez la vérification. Répétez
jusqu’à ce que le compteur tombe à zéro. Les remarques peuvent resterà : elles
décrivent un comportement, pas une faute.

:::note
Un enregistrement arrive sur le serveur une à deux secondes environ après
votre confirmation. Si une correction semble sans effet, attendez un instant
et relancez la vérification.
:::

### 4. Lire la confirmation de publication

La fenêtre de publication exécute ses propres vérifications et les affiche
avant votre confirmation :

- **Fermeture de composition.** Chaque lien parent/enfant doit être réciproque.
- **Barrière de version** (publication par-dessus un domaine existant). Chaque
  doctype modifié exige la version de schéma suivante et une migration pour
  l’étape.
- **Tickets d’attribution.** Les liens inter-domaines de votre fichier de
  définitions déposent un ticket auprès des domaines producteurs. La fenêtre
  rapporte chaque ticket et indique s’il arrive à l’état actif.
- **Avertissements.** Publier par-dessus un domaine réel ne transporte pas les
  hooks de domaine du brouillon. La fenêtre nomme les hooks que la publication
  laisse de côté.

## Exemple

La vérification d’un brouillon à un seul doctype renvoie ce rapportà :

```json
{
  "data": {
    "domain": "_a1b2c3",
    "issue_count": 1,
    "domain_issues": [],
    "doctypes": [
      {
        "doctype_id": "_a1b2c3.Order",
        "issue_count": 1,
        "issues": [
          {
            "severity": "error",
            "category": "reference",
            "field": "customer",
            "message": "Reference field 'customer' declares a bare doctype name 'Client' — declare the qualified '_a1b2c3.Client' form; bare names match no registered doctype and every value of this field is rejected"
          }
        ],
        "notices": []
      }
    ]
  }
}
```

La correction : ouvrez le doctype `Order`, remplacez la cible du champ par
`_a1b2c3.Client`, enregistrez, puis relancez la vérification. Le compteur
tombe à zéro et la confirmation de publication reste vierge.

## Dépannage

**Le compteur d’anomalies ne baisse pas.**

Le rapport lit les définitions enregistrées. Vérifiez que l’enregistrement est
bien arrivé, attendez un instant, puis relancez la vérification.

**Une anomalie nomme un doctype hors du brouillon.**

Les vérifications de réplication et de référence vont jusque dans les domaines
réels. Le défaut reste de votre côtéà : le brouillon pointe vers quelque chose
que l’autre domaine ne porte pas.

**La publication signale un échec de barrière de version.**

Le brouillon modifie un doctype qui existe sur la cible. Augmentez son
`schema_version` d’un cran et ajoutez la migration de l’étape. Voir
[Faire évoluer un schéma](/fr/build/evolving-schema/).

## Voir aussi

- [Domaines de brouillon, doc sur GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md) — les services de vérification et de publication en entier.
- [Brouillon et publication](/fr/concepts/draft-publish/) — comment un brouillon devient un domaine.
- [Domaines, brouillons et éditeurs de domaines](/fr/build/domains-drafts-editors/) — créez le brouillon et lancez la publication.
