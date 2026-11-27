---
title: Hooks d’événement et planifiés
description: Lancez des scripts Lua automatiquement quand les documents changent ou sur une planification cron.
audience: [author]
features: [AUT-02, AUT-08]
sidebar:
  order: 22
verified_at: fd345fe3
---

Un domaine peut embarquer sa propre automatisation. Un **hook d’événement**
exécute un script Lua quand un document change quelque part. Un **hook
planifié** en exécute un selon une planification cron. Les hooks vivent sur le
document du domaine : ils suivent le domaine quand vous le publiez ou
l’exportez.

## Quand l’utiliser

- Chaque nouveau contrat mis en attente doit alerter un réviseur.
- Un travail de consolidation doit tourner chaque nuit.
- Un script doit réagir aux changements d’un autre domaine, dans les limites
  d’une attribution.

## Avant de commencer

- **Le document du domaine.** Vous déclarez les hooks en modifiant le document
  du domaine, pas un doctype.
- **Les noms d’événements.** Repérez les noms qui vous concernent : `created`,
  `updated`, `deleted`, et les événements d’action émis par votre modèle.
- **Le bon outil.** Les hooks tournent dans Facet. Pour appeler un système
  externe, passez par un webhook. Voir [Webhooks sortants](/fr/build/model/automation/webhooks/).

## Où vivent les hooks

Un hook est une entrée de la liste `hooks` du document du domaine. Le
**script Lua** est une valeur séparée, et l’entrée y renvoie. Il y a deux
endroits pour écrire les deux.

**Dans l’application.** Ouvrez **Configurer → Domaines**, ouvrez le domaine,
puis l’onglet **Vue d’ensemble**. L’éditeur montre le nom et la description
du domaine ; il n’a pas de champ pour la liste `hooks`. Pour ajouter un hook
à cet endroit, envoyez un patch qui porte la liste complète — voir l’exemple
à la fin de cette page. Le hook est actif dès l’enregistrement du patch ;
aucun redémarrage n’est nécessaire.

**Dans les fichiers.** Le script du hook se trouve dans le dossier du
domaine, et `domain.yml` le lit avec la balise `!read_file` :

```text
equipment.facet-domain/
├── domain.yml
└── hooks/
    └── 1-booking-drives-stock.lua
```

```yml
content:
  color: "#0F766E"
  description: Rental equipment — items, categories, and maintenance tickets.
  hooks:
    - id: booking-drives-stock
      kind: event
      source:
        domain: rentals
        doc_type: Booking
        events:
          - booking_confirmed
          - booking_returned
      script: !read_file hooks/1-booking-drives-stock.lua
meta: {}
```

Le nom du fichier est libre. Un export nomme chaque script
`{i}-{hook_id}.lua`, où `{i}` est la position du hook dans la liste. Le
surveillant de développement applique le dossier à l’enregistrement suivant —
voir [Le surveillant de domaine](/fr/build/model/in-files/domain-watcher/).

## Étapes

### 1. Écrire l’entrée du hook

Un hook d’événement nomme une source et un script. Ajoutez une entrée à la
liste `hooks` :

```json
{
  "id": "alert-on-hold",
  "kind": "event",
  "source": { "domain": "accountancy", "doc_type": "Contract", "events": ["created"] },
  "script": "…"
}
```

| Élément | Signification |
| --- | --- |
| `id` | Requis. Unique dans le domaine. |
| `kind` | Requis. `event` pour un hook sur les changements, `schedule` pour un hook planifié. |
| `source.domain` | Requis. Le domaine à observer. |
| `source.doc_type` | Facultatif. Sans lui, le hook observe tous les doctypes du domaine. |
| `source.events` | Facultatif. Sans lui, le hook se déclenche à chaque événement. |
| `script` | Requis. Le texte Lua, ou `!read_file` en mode fichiers. |

La valeur `script` porte le texte du script, pas un chemin. En mode fichiers
seulement, `!read_file` lit le texte dans le fichier nommé. Ne collez pas le
Lua dans une chaîne JSON sur une ligne : gardez-le dans son propre fichier
`.lua` et faites pointer `script` dessus, comme ci-dessus.

### 2. Écrire le script

Le script est un module Lua. Il renvoie une table qui porte `on_event` pour
un hook d’événement, ou `on_schedule` pour un hook planifié. Un script qui
n’a pas cette fonction est refusé à l’enregistrement.

```lua
local export = {}

function export.on_event(ctx)
  if ctx.event.content.status == "on_hold" then
    ctx.error("Contract " .. ctx.event.doc_id .. " entered on-hold")
  end
end

return export
```

Dans le script, vous lisez et écrivez des documents avec `document.get`,
`document.list`, `document.create` et `document.update`, et vous prévenez des
personnes avec `notification.send`. Les écritures issues des hooks sont
marquées comme automatisées : un hook qui écrit ce qu’il observe ne peut pas
boucler. La surface complète est dans [la référence de l’API
Lua](/fr/reference/lua-api/).

### 3. Ajouter un hook planifié

Un hook planifié remplace la source par une expression cron : cinq champs
numériques, en UTC, avec des incréments `/` admis. Les macros comme `@daily`
et le champ des secondes sont refusés. Le script exporte `on_schedule` au
lieu de `on_event`. L’exemple ci-dessous montre une entrée planifiée
complète.

### 4. Enregistrer et observer l’exécution

Facet compile chaque script quand vous enregistrez le domaine. Un script qui
ne compile pas, ou qui ne définit pas la bonne fonction, est refusé. Une
modification prend effet au prochain événement ou au prochain passage
planifié, sans redémarrage.

:::caution
La livraison est au plus une fois, par conception. Une panne serveur pendant
un hook perd ce déclenchement ; rien ne le rejoue. Écrivez des hooks qui
tolèrent un manquement, ou faites tourner un hook planifié qui revérifie
l’état.
:::

## Exemple

Une consolidation qui compte chaque nuit les contrats actifs dans un document
`Dashboard` du domaine propriétaire. Déclarez le hook avec `kind: schedule`
et `schedule: "0 3 * * *"`. La valeur `script` est le texte ci-dessous :

```lua
local export = {}

function export.on_schedule(ctx)
  local ok, result = pcall(document.list, "Contract", { status = "active" })
  if not ok then
    ctx.error("roll-up failed: " .. tostring(result))
    return
  end
  local ok2, doc = pcall(document.get, "Dashboard", "01JD5R6Y8K31N4TQZ9W2B5XDEF")
  if not ok2 then
    ctx.error("dashboard row missing: " .. tostring(doc))
    return
  end
  local body = util.json_decode(doc.content)
  body.open_contracts = result.total
  document.update("Dashboard", "01JD5R6Y8K31N4TQZ9W2B5XDEF", body)
end

return export
```

```yml
hooks:
  - id: contract-roll-up
    kind: schedule
    schedule: "0 3 * * *"
    script: !read_file hooks/1-contract-roll-up.lua
```

La planification `"0 3 * * *"` l’exécute chaque jour à 03:00 UTC. Les lectures
et les écritures restent dans le domaine propriétaire, donc aucune attribution
n’est nécessaire.

:::note
Un hook sur une source étrangère ne se déclenche que si une attribution active
autorise le domaine propriétaire, et le script ne voit alors que les champs
accordés.
:::

## Dépannage

**Le hook ne se déclenche jamais.**

Vérifiez la source : le domaine doit être réel, le doctype doit exister, et
une source étrangère exige une attribution active. Un hook tout neuf part
aussi du moment présent ; il ne rejoue pas les événements passés.

**Le script échoue à l’exécution.**

Le déclenchement journalise l’erreur et continue. Corrigez le script et
enregistrez de nouveau le domaine ; rien ne rejoue le déclenchement manqué.

**Ma planification n’a pas tourné pendant une panne.**

Un passage manqué est perdu. L’échéance suivante s’exécute normalement.

## Voir aussi

- [Référence de l’API Lua](/fr/reference/lua-api/) — tous les globaux qu’un
  script de hook peut appeler.
- [Livraison des événements](/fr/admin/under-the-hood/events-and-delivery/) — comment les
  événements de changement circulent.
- [Webhooks sortants](/fr/build/model/automation/webhooks/) — appeler un système externe sur
  les mêmes événements.
