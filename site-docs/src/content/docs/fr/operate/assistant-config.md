---
title: Configurer l’assistant
description: Orientez l’assistant vers une API compatible OpenAI et réglez son modèle, son nom et ses paramètres de comportement.
audience: [operator]
features: [AI-08, AI-07, AI-09]
sidebar:
  order: 9
verified_at: 008dd880
---

L’assistant dialogue avec n’importe quelle API compatible OpenAI. En tant
qu’opérateur, vous choisissez l’endpoint, le modèle et le comportement des
tours. Les clés de connexion sont à chaud : dès que vous enregistrez
les paramètres, chaque conversation bascule vers la nouvelle connexion à

son tour suivant. Qui peut ouvrir l’assistant et combien chaque compte peut
dépenser relèvent des rôles — voir
[Gouverner l’assistant](/fr/govern/governing-assistant/).

## Quand l’utiliser

Configurez l’assistant quand :

- vous connectez un fournisseur pour la première fois,
- vous changez de modèle ou d’endpoint,
- vous plafonnez le registre de consommation et comprenez le balayage des
  tours périmés.

## Avant de commencer

- Vous détenez un rôle qui peut mettre à jour `core.SystemSettings`, ou
  vous pouvez modifier le fichier de configuration et redémarrer.
- Vous disposez d’une clé d’API pour le fournisseur.
- Les budgets de rôles plafonnent la dépense avant que l’un de ces
  paramètres n’entre en jeu — réglez-les d’abord si vous avez besoin de
  plafonds.

## Étapes

### 1. Régler la connexion

Épinglez la connexion sur la page **Configurer → Plateforme → Paramètres**,
ou réglez la section `assistant:` du fichier de configuration :

```yaml
assistant:
  name: Assistant
  api_endpoint: https://api.openai.com/v1
  api_key: !env FACET_AI_API_KEY
  model: gpt-4o
  system_prompt: "Answer in short sentences. Name the document you base each answer on."
  max_history: 40
  max_tokens: 2048
  temperature: 0.7
  auto_execute_tools: true
```

| Clé | Défaut | Signification |
| --- | --- | --- |
| `assistant.name` | `Assistant` | Le nom affiché sur chaque surface de l’assistant. |
| `assistant.api_endpoint` | `https://api.openai.com/v1` | L’endpoint compatible OpenAI. |
| `assistant.api_key` | aucune | La clé du fournisseur. Un champ secret ; la valeur est stockée scellée quand elle est épinglée. |
| `assistant.model` | `gpt-4o` | L’identifiant du modèle. |
| `assistant.system_prompt` | aucune | Instructions générales pour chaque nouvelle conversation. |
| `assistant.max_tokens` | aucune | Plafond de tokens de complétion par tour. |
| `assistant.temperature` | aucune | Température d’échantillonnage, de 0,0 à 2,0. |
| `assistant.max_history` | aucune | Tours conservés en contexte. Illimité si non défini. |
| `assistant.auto_execute_tools` | `true` | Résout automatiquement les appels d’outils enregistrés. |

Le contrôle à l’écriture borne les valeurs : température entre 0,0 et
2,0, `max_tokens` supérieur à 0, `max_history` supérieur ou égal à 0.

### 2. Savoir quand un changement atteint les conversations

La connexion est résolue à chaque début de tour. Un changement de modèle
ou d’endpoint déplace les conversations existantes à leur tour suivant. Le
prompt système est différent : chaque conversation fige son prompt à

la création, donc un changement de prompt n’atteint que les conversations
créées ensuite.

:::caution
Changer de modèle chez un même fournisseur est le chemin vérifié. Un
changement de fournisseur rejoue l’historique stocké vers le nouveau
fournisseur, et aucune spécification ne couvre ce rejeu. Vérifiez le
comportement sur une conversation neuve avant de changer de fournisseur en
production.
:::

### 3. Régler les paramètres réservés au fichier

Ces clés se fixent au démarrage et restent réservées au fichier :

```yaml
assistant:
  cancel_ttl_seconds: 15
  turn_timeout_seconds: 900
  turn_sweep_cron: "*/5 * * * *"
  usage_retention_days: 0
  usage_prune_cron: "30 4 * * *"
```

| Clé | Défaut | Signification |
| --- | --- | --- |
| `cancel_ttl_seconds` | `15` | Durée de vie d’un signal d’annulation dans Redis. |
| `turn_timeout_seconds` | `900` | Durée pendant laquelle un tour `running` peut rester sans basculer avant que le balayage ne le ferme. |
| `turn_sweep_cron` | `*/5 * * * *` | La planification du balayage des tours périmés. |
| `usage_retention_days` | `0` | Rétention du registre, en jours. `0` conserve chaque ligne. |
| `usage_prune_cron` | `30 4 * * *` | La planification de la purge du registre. |

### 4. Borner le registre de consommation

Chaque tour qui a produit une sortie écrit une ligne de registre : le
modèle, les tokens d’entrée et de sortie, et si le compte est une
estimation. Les budgets de rôles se comparent à une fenêtre glissante de
30 jours sur ce registre.

Si vous définissez `usage_retention_days`, gardez-le à 31 ou plus. Une
fenêtre de 1 à 30 sous-compte tous les budgets en cours, et la purge
quotidienne journalise un avertissement. La valeur par défaut `0` conserve
chaque ligne pour toujours.

:::tip
Chaque appelant peut lire son propre compteur sur
`GET /Api/assistant/usage`. La réponse porte le total glissant, le budget
effectif et le début de la fenêtre.
:::

### 5. Connaître le balayage des tours périmés

Un processus qui meurt en plein tour laisse sa ligne de tour à l’état
`running`. Le balayage tourne sur `turn_sweep_cron`, trouve les tours
`running` plus vieux que `turn_timeout_seconds` et les ferme : statut
`error` avec le message `interrupted`. Le client voit l’état terminal à sa
prochaine lecture. La passe est idempotente : elle ne touche jamais
une ligne déjà terminale.

## Exemple

Une section `assistant:` complète pour une passerelle auto-hébergée
compatible OpenAI :

```yaml
assistant:
  name: Atlas
  api_endpoint: https://llm.internal.example.tld/v1
  api_key: !env FACET_AI_API_KEY
  model: gpt-4o
  system_prompt: "Answer in short sentences. Name the document you base each answer on."
  max_history: 40
  max_tokens: 2048
  temperature: 0.7
  auto_execute_tools: true
  cancel_ttl_seconds: 15
  turn_timeout_seconds: 900
  turn_sweep_cron: "*/5 * * * *"
  usage_retention_days: 90
  usage_prune_cron: "30 4 * * *"
```

## Dépannage

**Chaque tour répond `429`.**

Le compte a dépassé son budget de rôle glissant. Élargissez le budget sur
le rôle — voir [Gouverner l’assistant](/fr/govern/governing-assistant/).

**Les nouvelles instructions ne s’appliquent pas.**

La conversation date d’avant le changement. Démarrez-en une nouvelle.

**Une conversation reste bloquée sur `running`.**

Le processus est mort en plein tour. Le balayage ferme le tour après
`turn_timeout_seconds` — statut `error`, message `interrupted` — soit
15 minutes par défaut.

**Le contrôle de budget sous-compte.**

`usage_retention_days` est réglé sous 31 : la purge efface des
lignes que la fenêtre de budget de 30 jours lit encore. Montez-le à 31 ou
plus, ou réglez `0`.

**L’assistant reçoit `401` ou `403` du fournisseur.**

L’endpoint ou la clé est erroné. Vérifiez `assistant.api_endpoint` et
ressaisissez `assistant.api_key` sur la page des paramètres.

## Voir aussi

- [Gouverner l’assistant](/fr/govern/governing-assistant/) — qui peut
  l’ouvrir et les budgets de tokens.
- [Utiliser l’assistant](/fr/workspace/assistant/) — la surface de
  l’espace de travail.
- [Paramètres système](/fr/operate/system-settings/) — les clés à chaud et
  la mécanique d’épinglage.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) —
  pourquoi l’assistant ne détient aucun droit propre.
- Internes sur GitHub :
  [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md),
  [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
