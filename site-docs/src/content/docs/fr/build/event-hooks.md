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
  du domaine.
- **Les noms d’événements.** Repérez les noms qui vous concernent : `created`,
  `updated`, `deleted`, et le reste du vocabulaire des mutations.
- **Le bon outil.** Les hooks tournent dans Facet. Pour appeler un système
  externe, passez par un webhook. Voir [Webhooks sortants](/fr/build/webhooks/).

## Étapes

### 1. Écrire l’entrée du hook

Ajoutez une entrée au tableau `hooks` du document du domaine. Un hook
d’événement nomme une source et porte un script :

```json
{
  "id": "alert-on-hold",
  "kind": "event",
  "source": { "domain": "accountancy", "doc_type": "Contract", "events": ["created"] },
  "script": "local export = {}\n\nfunction export.on_event(ctx)\n  if ctx.event.content.status == \"on_hold\" then\n    ctx.error(\"Contract \" .. ctx.event.doc_id .. \" entered on-hold\")\n  end\nend\n\nreturn export"
}
```

| Élément | Signification |
| --- | --- |
| `id` | Unique dans le domaine. |
| `source.domain` | Requis. Le domaine à observer. |
| `source.doc_type` | Facultatif. Sans lui, le hook observe tous les doctypes du domaine. |
| `source.events` | Facultatif. Sans lui, le hook se déclenche à chaque événement. |

### 2. Connaître la surface du script

La valeur `script` est du texte Lua. Elle renvoie une table avec `on_event`
(hooks d’événement) ou `on_schedule` (hooks planifiés), comme l’entrée
ci-dessus.

Dans le script, vous lisez et écrivez des documents avec `document.get`,
`document.list`, `document.create` et `document.update`, et vous prévenez des
personnes avec `notification.send`. Les écritures issues des hooks sont
marquées comme automatisées : un hook qui écrit ce qu’il observe ne peut pas
boucler.

### 3. Ajouter un hook planifié

Un hook planifié remplace la source par une expression cron : cinq champs
numériques, en UTC, avec des incréments `/` admis. Les macros comme `@daily`
et le champ des secondes sont refusés. L’exemple ci-dessous montre une entrée
planifiée complète.

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
`Dashboard` du domaine propriétaire. Déclarez le hook avec `kind: "schedule"`
et `schedule: "0 3 * * *"`. La valeur `script` est le texte ci-dessous :

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
- [Livraison des événements](/fr/concepts/events-delivery/) — comment les
  événements de changement circulent.
- [Webhooks sortants](/fr/build/webhooks/) — appeler un système externe sur
  les mêmes événements.
