---
title: Gouverner l’assistant
description: "Décidez qui ouvre l’assistant, plafonnez sa consommation de tokens, et réglez son nom, ses instructions et ses outils."
audience: [admin]
features: [AI-08, AI-07]
sidebar:
  order: 14
verified_at: fd345fe3
---

L’assistant fonctionne sous les droits du compte qui lui parle. Il ne porte
aucune permission à lui. Un administrateur décide qui peut l’ouvrir, combien
chaque compte peut dépenser, et comment il s’appelle.

## Quand l’utiliser

- Vous devez allumer l’assistant pour certains rôles et l’éteindre pour
  d’autres.
- Vous devez plafonner ce que chaque compte peut dépenser en tokens.
- Vous voulez que l’assistant suive les instructions de la maison.

## Avant de commencer

- **Les rôles.** Ils portent l’interrupteur et le budget — voir
  [Rôles et lignes de permission](/fr/govern/roles-permission-lines/).
- **Les paramètres de la plateforme.** Ils vivent sur un document que seuls
  les administrateurs peuvent modifier par défaut.

## Étapes

### 1. Ouvrir l’assistant à un rôle

La liste `connectivity` du rôle doit porter le canal `assistant` :

```json
{
  "name": "analyst",
  "connectivity": ["assistant"],
  "assistant_token_budget": 500000
}
```

Ce contenu de rôle ouvre l’assistant aux comptes qui le portent, et les
plafonne à 500 000 tokens sur une fenêtre glissante de 30 jours. La
barrière tourne à chaque requête. Retirez le canal du rôle, et l’accès
meurt à la requête suivante.

### 2. Régler le budget de tokens

`assistant_token_budget` est un entier sur le rôle. Vide signifie illimité.
Un budget de `0` signifie aucun token : le compte porte le canal, et chaque
tour est refusé.

Le budget effectif d’un compte est le plus grand budget parmi les rôles
qu’il porte qui activent l’assistant. Si l’un de ces rôles est illimité, le
compte est illimité.

| Rôle      | `connectivity`    | `assistant_token_budget` |
| --------- | ------------------ | -------------------------- |
| `analyst` | `["assistant"]`    | `500000`                   |
| `editor`  | `["assistant"]`    | `null`                     |

Un compte qui porte les deux rôles est illimité. Un compte qui ne porte que
`analyst` reçoit 500 000 tokens. Quand le total glissant atteint le budget,
le tour suivant répond `429`.

:::tip
Chaque appelant peut lire son propre compteur sur
`GET /Api/assistant/usage`. La réponse porte le total glissant, le budget
effectif, et le début de la fenêtre.
:::

### 3. Nommer l’assistant et écrire les instructions de la maison

Ouvrez **Configurer → Plateforme → Paramètres** et réglez :

- `assistant.name` — le nom d’affichage sur chaque surface de l’assistant.
  Défaut : `Assistant`.
- `assistant.system_prompt` — les instructions personnalisées. Facet les
  incorpore à chaque nouvelle conversation sous un en-tête
  `## Custom instructions`.

  Ou réglez les deux par l’API :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"name": "Atlas", "system_prompt": "Answer in short sentences. Name the document you base each answer on."}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

:::note[Les instructions atteignent les nouvelles conversations]
Une conversation incorpore son prompt à la création. Un changement de
réglages ne réécrit pas les conversations existantes. Un changement de
modèle ou de point d’entrée, si : les conversations existantes basculent à

leur prochain tour.
:::

### 4. Régler le comportement des outils et la connexion au modèle

`assistant.auto_execute_tools` sur le document des réglages contrôle la
résolution des outils. Le défaut `true` résout automatiquement les appels
d’outils enregistrés. Mettez-le à `false` pour éteindre la résolution
automatique.

Le même document porte la connexion au modèle — `assistant.api_endpoint`,
`assistant.api_key` (un secret), et `assistant.model`, plus les réglages
d’échantillonnage `assistant.max_tokens`, `assistant.temperature` et
`assistant.max_history`. Un changement de connexion atteint les
conversations existantes à leur prochain tour.

### 5. Gouverner l’assistant dans une app

Une surface d’app demande deux interrupteurs allumés en même temps :

- le champ `assistant_enabled` de l’app, éteint par défaut, et
- le canal `assistant` du rôle actif.

Facet vérifie les deux à chaque message. Une ligne d’app manquante refuse
par défaut. L’app peut aussi porter `assistant_prompt` avec des
instructions propres à l’app.

## Explication

### La disponibilité

Deux barrières décident de la disponibilité :

1. **La barrière du rôle.** La liste `connectivity` du rôle actif porte
   `assistant`. Facet lit le contenu du rôle en direct, à chaque requête.
2. **La barrière de l’app,** pour les conversations d’app. La ligne de
   l’app est vivante, l’indicateur est allumé, et le token nomme cette app.
   Facet relit l’app à chaque message.

Les requêtes sans identifiant sont refusées. Le principal anonymous n’ouvre
jamais l’assistant.

### Le registre d’usage

Chaque tour en streaming d’un compte facturable écrit une ligne de
registre : le modèle, les tokens d’entrée et de sortie, et si le décompte
est une estimation. La vérification de limite tourne avant chaque tour. Elle
compare le total glissant de 30 jours au budget effectif. Un budget
illimité saute la vérification.

La rétention du registre est la clé de configuration
`assistant.usage_retention_days`. Le défaut `0` garde chaque ligne. Si vous
fixez une fenêtre, gardez-la à 30 jours ou plus, pour que la purge ne
puisse pas effacer des lignes que la vérification de budget lit encore.
Les budgets bornent chaque compte ; ils ne se mettent pas en commun entre
comptes, et ils comptent des tokens, pas de l’argent.

### L’assistant ne porte aucun droit

Chaque appel d’outil hérite de l’identité de l’appelant : le rôle élu, les
périmètres de lignes, les étiquettes de champs, et l’attribution de l’app
quand il y en a une. Un document que l’appelant ne peut pas lire est
invisible pour l’assistant. Voir
[L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/).

Une écriture de document que l’assistant fait enregistre l’appelant comme
acteur. Les métadonnées de cause la marquent comme travail de l’assistant —
voir [Auditer l’activité](/fr/govern/auditing-activity/).

## Dépannage

### Un membre ne voit pas d’assistant

La liste de canaux du rôle actif ne contient pas `assistant`. Vérifiez le
rôle élu : un seul rôle est actif par requête, et les rôles ne fusionnent
jamais.

### Chaque tour répond `429`

Le compte a dépassé son budget glissant. Élargissez un budget de rôle, ou
attendez que l’ancien usage sorte de la fenêtre de 30 jours.

### Les nouvelles instructions ne s’appliquent pas

La conversation précède le changement. Démarrez une nouvelle conversation.

### Un chat d’app répond `403`

L’indicateur de l’app, l’app du token, ou le canal du rôle manque.

### Le nom n’a pas changé

Vérifiez que le document des réglages s’est enregistré. Le droit
d’écriture par défaut est réservé aux admins.

## Voir aussi

- [L’assistant](/fr/workspace/assistant/) — la surface de l’espace de
  travail.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) —
  le modèle de frontière.
- [Rôles et lignes de permission](/fr/govern/roles-permission-lines/) — où
  se trouve `connectivity`.
- [La portée des apps (attributions)](/fr/govern/app-grants/) — les
  interrupteurs côté app.
- Internes sur GitHub :
  [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md),
  [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
