---
type: explanation
title: Assistant et permissions
description: Les appels d’outils de l’assistant passent les mêmes vérifications d’autorisation qu’un appel REST, et le travail de l’assistant reste auditable.
audience: [admin, developer]
features: [AI-07, AI-08, RBC-10]
verified_at: eee55a2
sidebar:
  order: 5
---

Un tour d’assistant ressemble à une délégation de pouvoir : « trouve mes
réservations en retard et remets les retours en rayon ». Le modèle choisit
quels outils appeler, mais il ne décide rien des droits. Chaque appel
d’outil s’exécute sous les droits de la personne qui a demandé. Les
vérifications, les périmètres et la piste d’audit sont les mêmes que si
elle avait cliqué le bouton elle-même. Cette page suit un appel d’outil à
travers ces vérifications.

## Explication

*Le modèle choisit l’outil ; les droits de l’appelant choisissent la
réponse.*

<!-- d2
direction: down
caller: Caller asks in chat {class: external}
session: Assistant turn on the caller's auth context
model: Model picks a tool call
tools: Tool registry dispatch
enforcers: Read and write enforcers {class: decision}
result: Answer within the caller's rights {class: ok}
denied: Refusal the model must accept {class: danger}

caller -> session
session -> model
model -> tools
tools -> enforcers
enforcers -> result
enforcers -> denied
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9246da84-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9246da84-dark.svg" alt="Diagram" loading="lazy" />
</div>

### Un contexte d’authentification, du début à la fin

La route de streaming construit le contexte d’authentification de la
requête comme toute autre route. Elle lit le moyen d’authentification de
l’appelant lui-même : sa session, sa clé d’API, ou le token de l’app.
L’assistant ne fabrique jamais un contexte à part. Tout le tour, et chaque
appel d’outil qu’il contient, porte ce contexte unique : une identité, un
rôle élu.

### Les appels d’outils repassent le contrôle

Le registre d’outils présente les outils au modèle par classes — lecture,
écriture, action — filtrées par les lignes de permission du rôle actif. Un
rôle sans ligne de lecture ne voit jamais les outils de lecture. Mais la
visibilité est une commodité pour le modèle, jamais une frontière. Chaque
appel exécuté repasse le contrôle complet par doctype, exactement comme en
REST. Le contrôleur de lecture et le contrôleur d’écriture vérifient à
nouveau les lignes de permission du rôle, les périmètres de lignes et les
étiquettes de champs à chaque appel.

La conséquence est la garantie de frontière : un document que l’appelant
ne peut pas lire est invisible pour l’assistant. Un champ que son rôle ne
voit pas n’entre jamais dans un résultat d’outil. Une ligne hors de son
périmètre reçoit un refus sans divulgation, la même réponse qu’un appel
REST.

### Les refus font partie de la conversation

Un appel refusé n’est pas une page d’erreur ; c’est un résultat d’outil
que le modèle doit accepter. Le registre renvoie les mêmes messages sans
divulgation que REST, plus les diagnostics par champ des échecs de
validation. Un refus de classe se présente comme un refus sec. Un document
invisible répond introuvable. Le modèle peut réessayer avec de meilleurs
arguments, et il le fait.

Des refus identiques répétés déclenchent un garde-fou. Les deux premiers
refus identiques d’un tour renvoient l’enveloppe d’erreur normale. Le
troisième renvoie une enveloppe terminale dont le texte indique au modèle
que le refus est définitif. Une seconde enveloppe terminale pour le même
appel annule le tour : l’historique partiel reste, et le tour se termine
par le chemin d’annulation standard. Le garde-fou existe pour qu’un modèle
bloqué en boucle ne brûle pas des tokens à frapper une porte qui ne
s’ouvrira pas.

### Les écritures sont auditées comme travail de l’assistant

Quand un appel d’outil écrit, la mutation enregistre deux choses à la
fois :

- **L’acteur est l’appelant.** L’auteur de la mutation est le compte qui a
  demandé, sous son rôle élu.
- **La cause est le travail de l’assistant.** L’écriture porte une cause
  racine de type `assistant`, ainsi les surfaces d’audit peuvent montrer
  ce que l’assistant a piloté, séparé des clics propres au compte.

Une ligne réelle de l’instance en fonctionnement montre la forme :

```text
cause_kind:  assistant
cause_name:  domain-builder
channel:     internal
actioner_id: 06H1FKW9RRQX860BKXRBY3YT8V   ← le compte qui a demandé
```

Trouvez ces lignes avec les filtres d’audit — voyez
[Voir qui a fait quoi](/fr/admin/history/audit/).

### Trois surfaces, une seule différence

Trois surfaces d’assistant partagent le mécanisme ci-dessus, avec une
différence :

| Surface | Contexte d’authentification des appels d’outil |
| --- | --- |
| Assistant de l’espace de travail | Le contexte d’authentification propre à l’appelant, comme ci-dessus. |
| Assistant d’app | Le token de l’app appelante — le garde-fou refuse un token qui ne nomme aucune app ou une autre app, et chaque appel d’outil hérite du plafond d’attribution de l’app par-dessus le rôle de l’appelant. |
| Assistant du constructeur de domaine | Un principal de niveau système avec les outils des domaines brouillons ; les écritures sont attribuées au propriétaire de la conversation, ainsi l’audit nomme toujours l’humain. |

Le plafond de l’app est le plus strict des trois. Une conversation d’app
ne peut pas dépasser les attributions de l’app, même quand le rôle propre
de l’utilisateur le pourrait.

## Ce que cela change pour vous

- **Ce que vous regrettez, réglez-le sur le rôle, pas sur l’assistant.**
  Restreindre un rôle restreint l’assistant avec lui, au tour suivant.
- **Auditez les changements de l’assistant comme tout changement.** Ils
  atterrissent dans le même journal, avec l’appelant comme acteur et
  `assistant` comme cause.
- **Une conversation d’app est plafonnée deux fois** — par le rôle de
  l’utilisateur et par les attributions de l’app. Ni l’un ni l’autre seul
  n’est la limite ; l’intersection l’est.

## Voir aussi

- [Gouverner l’assistant](/fr/admin/assistant/govern/) — qui peut
  l’ouvrir, et les budgets de tokens — un niveau au-dessus.
- [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) —
  le modèle de frontière en mots simples.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) —
  les contrôleurs que chaque appel repasse.
- [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/) —
  le contexte d’authentification que porte le tour.
- [Outils d’agent](/fr/reference/agent-tools/) — le registre par lequel
  cette page passe.
- Internes sur GitHub : [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md),
  [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md).
