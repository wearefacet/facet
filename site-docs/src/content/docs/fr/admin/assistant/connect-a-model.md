---
title: Connecter un modèle de langage
description: Orientez l’assistant vers une API compatible OpenAI, testez la connexion et réglez le comportement des tours.
type: how-to
audience: [admin, operator]
features: [AI-08, AI-07, AI-09]
verified_at: 11202ad
sidebar:
  order: 0
---

Le rôle a bien activé l’assistant, mais chaque tour se termine en erreur : aucun modèle n’est connecté. Facet livre l’assistant désactivé — aucun fournisseur configuré, aucun plantage au démarrage. Vous le connectez à n’importe quelle API compatible OpenAI : un endpoint, une clé, un modèle. La connexion est à chaud : chaque enregistrement des paramètres bascule toutes les conversations vers la nouvelle connexion à leur tour suivant. Qui peut ouvrir l’assistant et combien chaque compte peut dépenser relèvent des rôles — voir [Gouverner l’assistant](/fr/admin/assistant/govern/).

## Quand l’utiliser

- Vous connectez un fournisseur pour la première fois.
- Vous changez de modèle ou d’endpoint.
- Vous bornez le registre de consommation et comprenez le balayage des tours périmés.

## Avant de commencer

- Vous détenez un rôle qui peut mettre à jour `core.SystemSettings` — c’est le cas du rôle `iam.Roles.admin` créé par l’initialisation — ou vous pouvez modifier le fichier de configuration et redémarrer.
- Vous disposez d’une clé d’API pour le fournisseur.
- Les [budgets de rôles](/fr/admin/assistant/govern/) plafonnent la dépense avant que l’un de ces paramètres n’entre en jeu — réglez-les d’abord si vous avez besoin de plafonds.

## Étapes

### 1. Régler la connexion

Ouvrez **Configurer → Plateforme → Paramètres système** et cherchez le groupe Assistant. Les champs de connexion sont :

| Champ | Défaut | Signification |
| --- | --- | --- |
| `assistant.api_endpoint` | `https://api.openai.com/v1` | L’endpoint compatible OpenAI. |
| `assistant.api_key` | non définie | La clé du fournisseur. Un secret : la page affiche *définie* ou *non définie*, jamais la valeur. |
| `assistant.model` | `gpt-4o` | L’identifiant du modèle. |

Tout modèle servi par l’endpoint fonctionne. Le choix arbitre entre coût, rapidité et qualité.

:::note
Perdu dans la multitude de modèles ? Nous recommandons [OpenRouter](https://openrouter.ai) avec le modèle `glm-5.3-flash` : une clé et un endpoint (`https://openrouter.ai/api/v1`) donnent accès à de nombreux modèles, et GLM 5.3 Flash équilibre performance, rapidité et coût. Amplitude, le créateur de Facet, utilise aussi DeepSeek v4.1 Flash ; il fonctionne bien, tant que la conversation reste en anglais. Un modèle de pointe comme Claude Opus 5.5 coûte plus cher et offre globalement les meilleures performances.
:::

Recopiez dans `assistant.model` l’identifiant exact du modèle, tel qu’il figure sur la page du modèle chez le fournisseur.

La même page porte la persona maison — voir [Gouverner l’assistant](/fr/admin/assistant/govern/) pour `assistant.name`, `assistant.system_prompt` et les curseurs de comportement.

### 2. Tester la connexion

Sélectionnez **Envoyer une requête de test**. Le bouton envoie une complétion minimale à travers les paramètres enregistrés — le même chemin qu’un tour de chat. Enregistrez d’abord toute modification en attente ; le test utilise les paramètres enregistrés.

Les réponses :

| Réponse | Signification |
| --- | --- |
| `200` `{model, endpoint, reply}` | Le fournisseur a répondu. |
| `422` | Aucune clé d’API n’est résolue. Le message nomme le correctif : *Set assistant.api_key (or the FACET_AI_API_KEY environment variable) and save before testing*. |
| `502` | Le fournisseur ou le transport a échoué. Le message reprend les mots du transport — `401 invalid_api_key` ou `connection refused` sert de diagnostic. |

La sonde ne lance jamais les outils d’agent, ne touche jamais une conversation et n’écrit jamais une ligne de tour. Elle appelle le fournisseur une seule fois, donc elle coûte une requête minuscule.

### 3. Comprendre la résolution des trois niveaux

Facet lit la connexion à chaque début de tour, dans un ordre fixe :

1. **Les paramètres de la plateforme.** Ce qu’un administrateur a enregistré sur la page des paramètres. La clé d’API repose dans un emplacement scellé ; la page n’affiche que définie ou non définie.
2. **Le fichier de configuration.** La section `assistant:` de `config.{env}.yml`. Les fichiers livrés lisent leurs valeurs dans l’environnement :

   ```yaml
   assistant:
     api_endpoint: !env? FACET_AI_API_ENDPOINT
     api_key: !env? FACET_AI_API_KEY
     model: !env? FACET_AI_MODEL
   ```

   `!env?` est le niveau facultatif : une variable absente réduit la clé à null, et l’assistant reste désactivé — aucun plantage au démarrage.
3. **La valeur intégrée par défaut.** Endpoint `https://api.openai.com/v1`, modèle `gpt-4o`, nom `Assistant`.

Une clé résolue par le niveau 1 ou 2, voilà ce que « configuré » signifie partout. Le payload de connexion l’expose comme `assistant.configured`. Quand il vaut `false`, le dock reste visible mais la création de conversation est désactivée. Le message nomme les paramètres système comme correctif.

### 4. Savoir quand un changement atteint les conversations

L’endpoint, la clé, le modèle et les curseurs d’échantillonnage se résolvent à chaque début de tour. Un changement atteint les conversations existantes à leur tour suivant. Le prompt système est différent : chaque conversation fige son prompt à la création, donc un changement de prompt n’atteint que les conversations créées ensuite.

:::caution
Changer de modèle chez un même fournisseur est le chemin pris en charge. Un changement de fournisseur rejoue l’historique stocké vers le nouveau fournisseur, et aucune spécification ne couvre ce rejeu. Vérifiez le comportement sur une conversation neuve avant de changer de fournisseur en production.
:::

### 5. Régler les curseurs réservés au fichier

Ces clés se lient au démarrage et restent réservées au fichier — la page des paramètres ne les porte pas :

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

### 6. Borner le registre de consommation

Chaque tour qui a produit une sortie écrit une ligne de registre : le modèle, les jetons d’entrée et de sortie, et si le décompte est une estimation. Les budgets de rôles se comparent à une fenêtre glissante de 30 jours sur ce registre.

Si vous définissez `usage_retention_days`, gardez-le à 31 ou plus. Une fenêtre de 1 à 30 sous-compte tous les budgets en cours, et la purge quotidienne journalise un avertissement. La valeur par défaut `0` conserve chaque ligne pour toujours.

:::tip
Chaque appelant peut lire son propre compteur sur `GET /Api/assistant/usage`. Depuis l’instance en cours :

```json
{
  "total": 43290,
  "estimated_total": 0,
  "budget": null,
  "window_start": "2026-10-27T14:53:01Z",
  "window_days": 30
}
```
:::

### 7. Comprendre le balayage des tours périmés

Un processus qui meurt en plein tour laisse sa ligne de tour à l’état `running`. Le balayage tourne sur `turn_sweep_cron`, trouve les tours `running` plus vieux que `turn_timeout_seconds` et les ferme : statut `error` avec le message `interrupted`. Le client voit l’état terminal à sa prochaine lecture. La passe est idempotente : elle ne touche jamais une ligne déjà terminale.

## Exemple

Une section `assistant:` complète pour une passerelle auto-hébergée compatible OpenAI, avec les curseurs réservés au fichier :

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

`!env` (sans le `?`) fait échouer le démarrage quand la variable manque. Utilisez-le quand le déploiement ne doit pas démarrer sans clé.

## Dépannage

**Chaque tour répond `429`.**

Le compte a dépassé son budget de rôle glissant. Élargissez le budget sur le rôle — voir [Gouverner l’assistant](/fr/admin/assistant/govern/).

**Les nouvelles instructions ne s’appliquent pas.**

La conversation précède le changement. Démarrez-en une nouvelle.

**Une conversation reste bloquée sur `running`.**

Le processus est mort en plein tour. Le balayage ferme le tour après `turn_timeout_seconds` — statut `error`, message `interrupted` — soit 15 minutes par défaut.

**Le contrôle de budget sous-compte.**

`usage_retention_days` est réglé sous 31 : la purge efface des lignes que la fenêtre de budget de 30 jours lit encore. Montez-le à 31 ou plus, ou réglez `0`.

**L’assistant reçoit `401` ou `403` du fournisseur.**

L’endpoint ou la clé est erroné. Vérifiez `assistant.api_endpoint` et ressaisissez `assistant.api_key` sur la page des paramètres.

## Voir aussi

- [Gouverner l’assistant](/fr/admin/assistant/govern/) — qui peut l’ouvrir et les budgets de jetons.
- [Demander à l’assistant](/fr/use/assistant/) — la surface de l’espace de travail.
- [Paramètres système](/fr/admin/configure/system-settings/) — les clés à chaud et la mécanique d’épinglage.
- [L’assistant : l’IA avec vos droits](/fr/discover/how-it-works/assistant/) — pourquoi l’assistant ne détient aucun droit propre.
- Internes sur GitHub : [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
- [L’IA et les permissions en détail](/fr/admin/under-the-hood/ai-and-permissions/)
