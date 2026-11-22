---
title: L’IA sous les droits de l’appelant
description: L’assistant et les agents externes agissent avec les droits de l’appelant et laissent les mêmes lignes d’audit.
audience: [admin, developer]
features: [AI-01, AI-04]
sidebar:
  order: 12
verified_at: 7a6cb462
---

L’assistant de l’espace de travail n’a aucune permission propre. Il agit dans
le contexte d’authentification du compte qui a ouvert la conversation. Il ne
voit et ne modifie que ce que ce compte peut voir et modifier. Les agents
externes se connectent via MCP (Model Context Protocol) et suivent la même
règle.

## Explication

<!-- d2
message: "Account sends a chat message" {class: external}
tool: "Assistant picks a tool"
check: "Enforcers check the caller's role" {class: decision}
denied: "Tool returns a denial" {class: danger}
write: "Write service runs the change"
audit: "Mutation row lands in the audit log" {class: store}

message -> tool
check -> denied: denied
check -> write: allowed
write -> audit
tool -> check
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e7f20cd9-light.svg" alt="Account sends a chat message" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e7f20cd9-dark.svg" alt="Account sends a chat message" loading="lazy" />
</div>

### Un seul chemin de contrôle

L’assistant de l’espace de travail est la surface de chat de l’application
principale. Il lit et écrit les documents réels, exécute des actions nommées,
calcule des agrégats et ouvre des pages pour l’utilisateur connecté. Chaque
appel d’outil tourne avec le contexte d’authentification de l’appelant.
Périmètres de lignes, visibilité des champs et refus se comportent
exactement comme sur une requête directe de ce compte. L’assistant ne peut
pas voir un document que le compte ne voit pas. Un refus est définitif, et le
prompt système l’indique au modèle.

**Le rôle conditionne l’accès.** Un rôle doit lister `assistant` dans son
tableau de connectivité avant qu’un compte puisse ouvrir le chat. Le backend
revérifie ce contrôle à chaque message du flux, si bien qu’un changement de
rôle s’applique au message suivant.

### Un catalogue d’outils unique

Les surfaces d’intelligence artificielle (IA) partagent un catalogue unique
d’outils de documents. L’assistant de l’espace de travail le monte, et chaque
client MCP voit les mêmes entrées. La liste qu’un agent voit est filtrée selon
les droits du rôle épinglé dans l’URL MCP. Le filtrage est une commodité, pas
une limite. Le contrôle s’exécute à nouveau au moment de l’appel, dans les
mêmes contrôleurs que pour toute requête directe.

Le catalogue ne porte que des outils de documents. Un agent peut créer, lire,
modifier et supprimer des documents, exécuter des actions et rechercher. Il ne
peut pas enregistrer de doctypes, publier des domaines ni modifier des
attributions.

### La même piste d’audit

Chaque écriture d’un outil passe par les services d’écriture ordinaires. Elle
atterrit comme une ligne de mutation dans le journal d’audit, attribuée au
compte de l’appelant. Les écritures de l’assistant portent une cause
`assistant`, si bien que le journal les marque comme pilotées par le modèle.
Les écritures via MCP portent la même cause `request` qu’une requête directe.
Rien de ce qu’un agent fait n’échappe à l’audit.

**Pourquoi pas un compte de service IA séparé ?** Un tel compte aurait besoin
de droits larges pour servir chaque appelant. Ses permissions s’écarteraient
du modèle de rôles. Ses lignes d’audit nommeraient le service, pas la personne
qui a demandé. Sous les droits de l’appelant, révoquer un rôle coupe aussi
l’assistant. Chaque action remonte au compte qui l’a provoquée. Le même modèle
sert les apps : l’assistant par app tourne sous le contexte d’authentification
de l’app appelante, plafonné par son attribution.

:::note
L’assistant de construction de domaines est l’exception. Il modifie des
définitions de doctypes dans un domaine de brouillon sous un principal de
niveau système, chaque outil d’écriture restant limité à ce brouillon. Ses
lectures portent plus loin ; ses écritures restent dans le brouillon.
:::

**Le prix est la symétrie.** Le même prompt renvoie des résultats différents
selon les comptes, car chaque réponse est limitée aux droits de l’appelant.
L’assistant ne peut pas aider sur ce que l’appelant ne voit pas. Il ne peut
pas agir pour un compte aux droits plus larges, ni augmenter son propre
accès.

## Voir aussi

- [Contextes d’authentification](/fr/concepts/auth-contexts/) — le modèle
  d’identité et de rôles derrière chaque canal.
- [Contrôle des autorisations](/fr/concepts/authorization-enforcement/) — les
  contrôleurs que chaque appel d’outil traverse.
- [Apps](/fr/apps/) — les apps embarquent l’assistant sous leur propre
  attribution.
- [Sécurité et gouvernance](/fr/start/security-governance/) — rôles,
  attributions et audit en une seule image.
- Internes sur GitHub : [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md),
  [workspace-assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/workspace-assistant.md).
