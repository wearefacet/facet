---
type: how-to
title: Vérifier avant de publier
description: Lancez l’outil de vérification sur un brouillon et traitez ses anomalies avant de publier — les mêmes diagnostics tournent en mode fichiers.
audience: [author]
features: [DOM-16, DOM-19]
sidebar:
  order: 3
verified_at: eee55a2
---

Un domaine de brouillon embarque un outil de vérification. Il lit chaque
doctype du domaine et rapporte ce qui ne fonctionnerait pas après la
publication. Lancez-le à chaque édition. La publication revérifie ensuite
les règles qui impliquent des domaines réels, et la fenêtre de publication
affiche le résultat avant toute écriture.

## Quand l’utiliser

- Avant de publier un brouillon.
- Après avoir ajouté une référence, un champ de réplication ou un modèle de
  vue.
- Quand la page d’accueil du Builder affiche un compteur d’anomalies sur
  une carte de brouillon.

## Avant de commencer

- **Un [domaine de brouillon](/fr/build/model/in-app/how-drafts-work/)**
  dont vous détenez le droit de mise à jour.
- **Rien à perdre.** La vérification est en lecture seule. Elle n’écrit
  rien.

## Étapes

### 1. Lancer la vérification

Ouvrez le brouillon dans le Builder et ouvrez l’onglet **Vérification**.
La page d’accueil affiche aussi un compteur d’anomalies sur chaque carte de
brouillon. Depuis un terminal, la vérification tient en une lecture du
domaine :

<!-- screenshot: builder-check-tab -->

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/core/Domain/_a1b2c3/check"
```

### 2. Lire les anomalies et les remarques

Le rapport se répartit en deux sortes d’entrées :

| Type | Signification |
| --- | --- |
| Anomalie (avertissement ou erreur) | Un vrai défaut. La confirmation de publication les compte. |
| Remarque (info) | Un repli voulu, pas une faute. Par exemple, un type de vue manquant, ou l’absence de modèle `display_name`. |

Un défaut bloque aussi les écritures, et pas seulement le rapport : un
champ référence déclaré avec un nom non qualifié tel que `Client` (sans
préfixe `domain.`) rejette toute valeur de ce champ. La vérification le
marque comme une erreur. Un autre cas d’erreur : un doctype racine
d’agrégat — un doctype qui se tient seul — sans modèle `display_name` ni
modèle `search` reste invisible pour toutes les surfaces de recherche ; la
vérification le remonte donc aussi comme une erreur.

### 3. Corriger et relancer

Chaque anomalie nomme une catégorie et souvent un champ :

| Catégorie | Concerne |
| --- | --- |
| `reference` | Un doctype cible non enregistré, ou un nom de cible non qualifié. |
| `children` | Un doctype enfant non enregistré dans le domaine. |
| `composition` | Un lien parent/enfant à sens unique, un `aggregate_root` manquant, ou un enfant modélisé comme référence. |
| `replication` | Un champ de réplication dont la source, le type, les étiquettes ou l’attribution ne tient pas. |
| `view` | Un modèle de vue cassé, ou un modèle lié à un champ inconnu. |
| `template` | Un modèle de libellé ou de recherche sans aucune variable. |
| `actions` | Des actions nommées sans script. |
| `compute` | Des champs calculés sans script — les champs restent non renseignés à chaque écriture. |
| `hooks` | Un hook de domaine qui ne compile pas. |

Corrigez la définition dans l’éditeur, puis relancez la vérification.
Répétez jusqu’à ce que le compteur tombe à zéro. Les remarques peuvent
rester : elles décrivent un comportement, pas une faute.

:::note
Un enregistrement arrive sur le serveur une à deux secondes environ après
votre confirmation. Si une correction semble sans effet, attendez un
instant et relancez la vérification.
:::

### 4. Lire la confirmation de publication

La fenêtre de publication lance ses propres vérifications et les affiche
avant votre confirmation :

- **Fermeture de la composition.** Chaque lien parent/enfant doit être
  réciproque.
- **Barrière de version** (publication sur un domaine existant). Chaque
  doctype modifié a besoin de la version de schéma suivante et d’une
  migration pour cette étape.
- **Demandes d’accès.** Les liens inter-domaines de vos définitions
  déposent des demandes auprès des domaines producteurs. La fenêtre
  rapporte chaque demande et indique si elle devient active.
- **Avertissements.** La publication sur un domaine réel ne reprend pas les
  hooks de domaine du brouillon. La fenêtre nomme les hooks que la
  publication laisse de côté.

## Les mêmes diagnostics en mode fichiers

Le mode fichiers lance le même service de vérification après chaque
synchronisation du watcher. Vous n’ouvrez jamais d’onglet pour cela ; les
résultats vous parviennent à deux endroits.

Le journal du serveur porte une ligne par domaine synchronisé — un domaine
propre ne journalise rien :

```text
[dev-sync] check for 'equipment': 2 issue(s) — first: Reference field 'customer'
declares a bare doctype name 'Client' … — full report: GET /Api/dev/check-report?domain=equipment
```

Le rapport complet de la dernière vérification achevée s’obtient par un
endpoint, qu’un agent ou un script peut lire :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "http://127.0.0.1:3000/Api/dev/check-report?domain=equipment"
```

Le rapport est un instantané du dernier cycle du watcher, avec un
horodatage `captured_at`. Il n’existe que sur un serveur de dev — en
production, la route répond `404`. Une synchronisation qui échoue à la
validation est son propre marqueur : la ligne du journal porte les erreurs
de champ, et la route du rapport répond avec un enregistrement
`import_failure` jusqu’à la prochaine sauvegarde correcte.

## Exemple

La vérification d’un brouillon avec un doctype renvoie ce rapport :

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

La correction : ouvrez le doctype `Order`, changez la cible du champ en
`_a1b2c3.Client`, enregistrez, et relancez la vérification. Le compteur
tombe à zéro et la confirmation de publication reste vierge.

## Dépannage

**Le compteur d’anomalies ne baisse pas.**

Le rapport lit les définitions enregistrées. Confirmez que la sauvegarde
est arrivée, attendez un instant, et relancez la vérification.

**Une anomalie nomme un doctype hors du brouillon.**

Les vérifications de réplication et de référence regardent dans les
domaines réels. Le défaut reste de votre côté : le brouillon pointe vers ce
que l’autre domaine ne porte pas.

**La publication rapporte un échec de barrière de version.**

Le brouillon modifie un doctype qui existe sur la cible. Augmentez son
`schema_version` d’un cran et ajoutez la migration pour cette étape. Voir
[Faire évoluer un schéma](/fr/build/model/change-a-live-domain/).

## Voir aussi

- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/)
  — le flux de publication, étape par étape.
- [Le fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/)
  — ce que la publication revérifie par-dessus.
- [Le watcher de domaines de dev](/fr/build/model/in-files/domain-watcher/)
  — où les mêmes diagnostics apparaissent en mode fichiers.
- Internes sur GitHub : [draft-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md).
- [L’organisation des fichiers du domaine](/fr/build/model/in-files/domain-files/)
