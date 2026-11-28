---
title: Gouverner l’assistant
description: Décidez qui peut ouvrir l’assistant, plafonnez la dépense de jetons de chaque compte et consultez ce qu’il a changé.
type: how-to
audience: [admin]
features: [AI-08, AI-07]
verified_at: eee55a2
sidebar:
  order: 1
---

L’assistant peut lire et modifier des documents au nom d’un membre. C’est utile, et c’est exactement pourquoi vous le gouvernez. L’assistant agit sous les droits du compte qui lui parle. Il ne porte aucune permission propre. Un administrateur décide qui peut l’ouvrir, combien chaque compte peut dépenser, et comment il s’appelle.

## Quand l’utiliser

- Vous devez activer l’assistant pour certains rôles et le désactiver pour d’autres.
- Vous devez plafonner ce que chaque compte peut dépenser en jetons.
- Vous voulez répondre à « qu’a changé l’assistant ?  » à partir du journal d’audit.

## Avant de commencer

- **Les rôles.** Ils portent l’interrupteur et le budget — voir [Rôles et permissions](/fr/admin/people/roles-and-permissions/).
- **Un modèle connecté.** L’interrupteur de rôle et le budget décident qui peut essayer ; la connexion décide si un tour peut réussir — voir [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/).

## Étapes

### 1. Ouvrir l’assistant à un rôle

La liste `connectivity` du rôle doit porter le canal `assistant`. Dans l’onglet Détails du rôle, c’est l’interrupteur **Accès à l’assistant de l’espace de travail** :

```json
{
  "name": "analyst",
  "connectivity": ["assistant"],
  "assistant_token_budget": 500000
}
```

Ce contenu de rôle ouvre l’assistant aux comptes qui le portent, et les plafonne à 500 000 jetons sur une fenêtre glissante de 30 jours. La barrière tourne à chaque requête et lit le rôle en direct. Retirez le canal du rôle, et l’accès meurt à la requête suivante.

### 2. Régler le budget de jetons

`assistant_token_budget` est un entier sur le rôle. Vide signifie illimité. Un budget de `0` signifie aucun jeton : le compte porte le canal, et chaque tour est refusé.

Le budget effectif d’un compte est le plus grand budget parmi les rôles qu’il porte qui activent l’assistant. Si l’un de ces rôles est illimité, le compte est illimité.

| Rôle | `connectivity` | `assistant_token_budget` |
| --- | --- | --- |
| `analyst` | `["assistant"]` | `500000` |
| `editor` | `["assistant"]` | null |

Un compte qui porte les deux rôles est illimité. Un compte qui ne porte que `analyst` reçoit 500 000 jetons. Quand le total glissant atteint le budget, le tour suivant répond `429`.

:::tip
Chaque appelant peut lire son propre compteur sur `GET /Api/assistant/usage`. La réponse porte le total glissant, le budget effectif et le début de la fenêtre.
:::

### 3. Nommer l’assistant et écrire les instructions de la maison

Ouvrez **Configurer → Plateforme → Paramètres système** et réglez :

- `assistant.name` — le nom affiché sur chaque surface de l’assistant. Défaut : `Assistant`.
- `assistant.system_prompt` — les instructions personnalisées. Facet les fige dans chaque nouvelle conversation sous un en-tête `## Custom instructions`.

Ou réglez les deux par l’API :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"name": "Atlas", "system_prompt": "Answer in short sentences. Name the document you base each answer on."}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

:::note[Les instructions atteignent les nouvelles conversations]
Une conversation fige son prompt à la création. Un changement de paramètres ne réécrit pas les conversations existantes. Un changement de modèle ou d’endpoint, si : les conversations existantes basculent à leur tour suivant.
:::

### 4. Régler le comportement des outils

`assistant.auto_execute_tools` sur le document de paramètres contrôle la résolution des outils. Le défaut `true` résout automatiquement les appels d’outils enregistrés. Mettez-le à `false` pour désactiver la résolution automatique.

La connexion au modèle repose sur le même document — voir [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/) pour l’endpoint, la clé, le modèle et les curseurs d’échantillonnage.

### 5. Gouverner l’assistant dans une app

Une surface d’app demande deux interrupteurs activés en même temps :

- le champ `assistant_enabled` de l’app, désactivé par défaut, et
- le canal `assistant` du rôle actif.

Facet vérifie les deux à chaque message. Une ligne d’app manquante refuse par défaut. L’app peut aussi porter `assistant_prompt` avec des instructions propres à l’app, qui n’atteignent que les nouvelles conversations.

Un type d’app ne demande aucune note ici : une app confidentielle peut activer l’assistant comme n’importe quelle autre app. La barrière vérifie l’indicateur et le token de l’appelant ; elle ne vérifie jamais le type de client de l’app.

## Comment les barrières décident

Deux barrières décident de la disponibilité :

1. **La barrière du rôle.** La liste `connectivity` du rôle actif porte `assistant`. Facet lit le contenu du rôle en direct, à chaque requête.
2. **La barrière de l’app**, pour les conversations d’app. La ligne de l’app est en direct, l’indicateur est activé, et le token nomme cette app. Facet relit l’app à chaque message.

Les requêtes sans identifiant sont refusées. Le principal anonyme n’ouvre jamais l’assistant.

## Le registre de consommation

Chaque tour en streaming d’un compte facturable écrit une ligne de registre : le modèle, les jetons d’entrée et de sortie, et si le décompte est une estimation. Le contrôle de limite tourne avant chaque tour. Il compare le total glissant de 30 jours au budget effectif. Un budget illimité saute le contrôle.

La rétention du registre est la clé de configuration `assistant.usage_retention_days`. Le défaut `0` garde chaque ligne. Si vous fixez une fenêtre, gardez-la à 31 jours ou plus, pour que la purge ne puisse pas effacer des lignes que le contrôle de budget lit encore. Les budgets bornent chaque compte ; ils ne se mettent pas en commun entre comptes, et ils comptent des jetons, pas de l’argent.

## L’assistant agit en votre nom

Chaque appel d’outil hérite de l’identité de l’appelant : le rôle élu, les périmètres de lignes, les étiquettes de champs, et l’attribution de l’app quand il y en a une. Un document que l’appelant ne peut pas lire est invisible pour l’assistant. Voir [L’assistant : l’IA avec vos droits](/fr/discover/how-it-works/assistant/) pour le modèle de frontière, et [L’IA et les permissions en détail](/fr/admin/under-the-hood/ai-and-permissions/) pour la mécanique.

Ce que l’assistant change est auditable. Une écriture de document faite par l’assistant enregistre l’appelant comme acteur, et les métadonnées de cause la marquent comme travail de l’assistant. Trouvez ces lignes dans le journal d’audit — voir [Voir qui a fait quoi](/fr/admin/history/audit/).

## Dépannage

### Un membre ne voit pas l’assistant

La liste de canaux du rôle actif ne contient pas `assistant`. Vérifiez le rôle élu : un seul rôle est actif par requête, et les rôles ne fusionnent jamais.

### Chaque tour répond `429`

Le compte a dépassé son budget glissant. Élargissez un budget de rôle, ou attendez que l’ancienne consommation sorte de la fenêtre de 30 jours.

### Les nouvelles instructions ne s’appliquent pas

La conversation précède le changement. Démarrez une nouvelle conversation.

### Un chat d’app répond `403`

L’indicateur de l’app, l’app du token, ou le canal du rôle manque.

### Le nom n’a pas changé

Vérifiez que le document de paramètres s’est enregistré. Le droit d’écriture par défaut est réservé aux administrateurs.

## Voir aussi

- [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/) — la connexion derrière les barrières.
- [Demander à l’assistant](/fr/use/assistant/) — la surface de l’espace de travail.
- [L’assistant : l’IA avec vos droits](/fr/discover/how-it-works/assistant/) — le modèle de frontière.
- [Rôles et permissions](/fr/admin/people/roles-and-permissions/) — où se trouve `connectivity`.
- [Contrôler ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) — les interrupteurs côté app.
- [L’IA et les permissions en détail](/fr/admin/under-the-hood/ai-and-permissions/) — une couche plus bas : comment les vérifications tournent.
- Internes sur GitHub : [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
