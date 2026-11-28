---
type: how-to
title: "Hooks d’événement et planifiés"
description: Exécutez des hooks Lua automatiquement quand les documents changent, et planifiez des tâches avec cron.
audience: [author]
features: [AUT-02, AUT-08, AUT-09]
sidebar:
  order: 0
verified_at: eee55a2
---

Quand une réservation Brightwater est confirmée, ses articles doivent sortir du stock de l’entrepôt, d’un domaine à l’autre, sans que personne ne clique. Cette page demande un peu de Lua : une introduction de dix lignes suffit, et la surface complète se trouve dans la [Référence de l’API Lua](/fr/reference/lua-api/). Un **hook** est un script Lua que le domaine possède et que Facet exécute automatiquement : un **hook d’événement** se déclenche quand un document change quelque part, un **hook planifié** se déclenche selon une planification cron. Les hooks vivent sur le document du domaine, donc ils suivent le domaine quand vous le publiez ou l’exportez.

## Quand l’utiliser

- Un changement d’état dans un doctype doit mettre à jour des documents d’un autre doctype.
- Une consolidation ou un résumé doit s’exécuter chaque nuit.
- Un script doit réagir aux changements d’un autre domaine, dans le cadre de l’attribution.

## Avant de commencer

- **Le document du domaine.** Vous déclarez les hooks en modifiant le document du domaine lui-même, pas un doctype.
- **Les noms d’événements.** Identifiez les événements qui vous concernent : `created`, `updated`, `deleted`, et les événements d’action que votre modèle émet.
- **Le bon outil.** Les hooks s’exécutent dans Facet. Pour appeler un système externe, utilisez un webhook — voir [Envoyer des webhooks](/fr/build/model/automation/webhooks/).

## Où vivent les hooks

Un hook est une entrée de la liste `hooks` du document du domaine. Le **script Lua** est une valeur séparée, et l’entrée pointe vers lui. Deux emplacements permettent d’écrire les deux.

**Dans l’application.** Ouvrez **Configurer → Domaines**, ouvrez le domaine, puis l’onglet **Vue d’ensemble**. L’éditeur affiche le nom et la description du domaine ; il n’a pas de champ pour la liste `hooks`. Pour ajouter un hook à cet endroit, envoyez un patch qui porte la liste complète — voir l’exemple à la fin de cette page. Le hook est actif dès l’enregistrement du patch ; aucun redémarrage n’est nécessaire.

**Dans les fichiers.** Le script du hook se trouve dans le dossier du domaine, et `domain.yml` le lit avec la balise `!read_file` :

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

Le nom du fichier est libre. Un export nomme chaque script `{i}-{hook_id}.lua`, où `{i}` est la position du hook dans la liste. Le watcher de développement applique le dossier au prochain enregistrement — voir [Le watcher de domaine](/fr/build/model/in-files/domain-watcher/).

## Déclarer un hook d’événement

Un hook d’événement nomme une source et un script. Ajoutez une entrée à la liste `hooks` :

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
| `kind` | Requis. `event` pour un hook sur les changements, `schedule` pour un hook cron. |
| `source.domain` | Requis. Le domaine à observer. |
| `source.doc_type` | Facultatif. Sans lui, le hook observe tous les doctypes de ce domaine. |
| `source.events` | Facultatif. Sans lui, le hook se déclenche à chaque événement. |
| `script` | Requis. Le texte Lua, ou `!read_file` en mode fichiers. |

La valeur `script` porte le texte du script lui-même, pas un chemin. En mode fichiers uniquement, `!read_file` lit le texte dans le fichier nommé. Ne collez pas le Lua dans une chaîne JSON sur une seule ligne : gardez-le dans son propre fichier `.lua` et faites pointer `script` dessus, comme ci-dessus.

## Écrire le script

Le script est un module Lua. Il renvoie une table qui porte `on_event` pour un hook d’événement, ou `on_schedule` pour un hook planifié. Un script sans cette fonction est refusé à l’enregistrement.

```lua
local export = {}

function export.on_event(ctx)
  if ctx.event.content.status == "on_hold" then
    ctx.error("Contract " .. ctx.event.doc_id .. " entered on-hold")
  end
end

return export
```

Dans le script, vous lisez et écrivez des documents avec les aides `document.*`, et vous notifiez des personnes avec `notification.send`. La surface complète se trouve dans la [Référence de l’API Lua](/fr/reference/lua-api/).

Un hook d’événement reçoit le changement dans `ctx.event`. Ses membres :

| Membre | Signification |
| --- | --- |
| `ctx.event.domain`, `ctx.event.doc_type`, `ctx.event.doc_id` | Le document qui a changé. |
| `ctx.event.event` | Le nom de l’événement. |
| `ctx.event.content` | Les valeurs de champs du document, sous forme de table Lua. La table est vide quand le document a été supprimé. |
| `ctx.error(msg)` | Consigne une erreur pour le journal. |
| `ctx.now` | L’heure UTC courante, en texte ISO 8601. |

Un événement porte une forme différente : une trame agrégée `child_changed` transporte une enveloppe — l’identifiant du parent, l’action et des pointeurs vers l’enfant et le parent — et non les valeurs de champs de l’enfant. Un hook qui a besoin du corps de l’enfant le récupère avec `document.get`.

Les écritures issues des hooks sont marquées comme automatisées : un hook qui écrit ce qu’il observe ne peut pas boucler. Un hook sur une source **étrangère** ne se déclenche que si une attribution active autorise le domaine propriétaire, et le script ne voit alors que les champs accordés — les champs du même domaine restent complets.

## Ajouter un hook planifié

Un hook planifié échange la source contre une expression cron : cinq champs numériques, en UTC, avec des pas `/` autorisés. Les macros comme `@daily` et le champ des secondes sont refusés. Chaque déclenchement s’exécute une fois par cluster, même sur une installation multi-serveurs.

```json
{ "id": "morning-digest", "kind": "schedule", "schedule": "0 6 * * *", "script": "…" }
```

Le script exporte `on_schedule` au lieu de `on_event`. L’exemple ci-dessous en montre un complet.

## Enregistrer et suivre l’exécution

Facet compile chaque script à l’enregistrement du domaine. Un script qui ne compile pas, ou qui n’a pas la bonne fonction, est refusé. Une modification prend effet au prochain événement ou au prochain passage, sans redémarrage.

Lisez le journal du serveur pour voir un déclenchement. Chaque appel `ctx.error` écrit une ligne avec le message ; le changement qui a déclenché le hook reste enregistré.

## La livraison, sans détour

La livraison des événements est **au plus une fois, par conception**. PostgreSQL conserve l’état durable ; le bus d’événements est un chemin de réaction, pas un registre. Une panne serveur pendant un déclenchement perd ce déclenchement : Facet le journalise et le compte sur le point de terminaison `GET /Healthcheck`, sous `event_loss`. Rien ne le rejoue. Écrivez des hooks qui tolèrent un manquement — revérifiez l’état au prochain événement, ou faites tourner un hook planifié qui relit l’état du monde. Le contrat complet se trouve dans [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/).

Deux autres limites découlent de la même décision. Un hook tout neuf part du moment présent : il ne rejoue pas les événements passés. Et un domaine qui gagne son premier hook après un démarrage du serveur se connecte en quelques secondes ; les événements déclenchés dans cette courte fenêtre ne lui parviennent pas.

## Exemple

Le domaine equipment de Brightwater porte ce hook, complet et en fonctionnement sur l’instance d’exemple. D’abord le script, puis la déclaration qui pointe vers lui :

```lua
-- booking-drives-stock — hook du domaine equipment
-- Se déclenche quand une réservation (Booking) du domaine rentals est confirmée
-- ou rendue. Une réservation confirmée marque ses articles sortis ; une
-- réservation rendue les ramène. La lecture inter-domaine des lignes de la
-- réservation exige une attribution active de rentals vers equipment.
local export = {}

function export.on_event(ctx)
    local ev = ctx.event
    if ev.doc_type ~= "Booking" then
        return
    end
    local status = ev.content and ev.content.status
    if status ~= "confirmed" and status ~= "returned" then
        return
    end

    local target = status == "confirmed" and "out" or "available"

    -- Liste les lignes de la réservation dans l’autre domaine. Sans
    -- attribution active, la lecture lève une erreur ; le pcall la
    -- transforme en erreur recueillie.
    local ok, result = pcall(document.list, "rentals.BookingLine", { parent_id__eq = ev.doc_id })
    if not ok then
        ctx.error("Could not read the booking's lines: " .. tostring(result))
        return
    end

    for _, line in ipairs(result.items or {}) do
        local content = util.json_decode(line.content or "{}")
        local ref = content.item
        if ref then
            -- La référence stocke la forme qualifiée equipment.Item.<id> ;
            -- la lecture et l’écriture demandent l’identifiant nu.
            local item_id = string.match(ref, "([^%.]+)$")
            -- Lit d’abord l’état courant de l’article. Un article en
            -- réparation ne peut pas partir sur une réservation : recueille
            -- le refus et laisse cet article en réparation — le reste de la
            -- réservation part quand même.
            local ok_item, proj = pcall(document.get, "Item", item_id)
            if not ok_item then
                ctx.error("Item " .. tostring(ref) .. ": " .. tostring(proj))
            else
                local item = util.json_decode(proj.content or "{}")
                if target == "out" and item.status == "in_repair" then
                    ctx.error("Item " .. tostring(ref) .. " is in repair and cannot be booked out")
                else
                    local done, err = pcall(document.update, "Item", item_id, { status = target })
                    if not done then
                        ctx.error("Item " .. tostring(ref) .. ": " .. tostring(err))
                    end
                end
            end
        end
    end
end

return export
```

En mode fichiers, le script se trouve dans `hooks/1-booking-drives-stock.lua`, et `domain.yml` porte la déclaration — le fichier complet est dans [Où vivent les hooks](#où-vivent-les-hooks). La déclaration nomme la source et les deux événements d’action :

```yml
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
```

Pour envoyer la même déclaration depuis l’application, envoyez un PATCH au document du domaine avec la liste dans `content.hooks` :

```sh
curl -X PATCH "$(facet-cli host)/Api/core/Domain/equipment" \
  -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{
    "hooks": [{
      "id": "booking-drives-stock",
      "kind": "event",
      "source": {
        "domain": "rentals",
        "doc_type": "Booking",
        "events": ["booking_confirmed", "booking_returned"]
      },
      "script": "local export = {}\n\nfunction export.on_event(ctx)\n  -- …\nend\n\nreturn export"
    }]
  }'
```

La clé `hooks` est remplacée en bloc : envoyez tous les hooks que le domaine conserve, pas seulement le nouveau.

Un hook planifié suit la même forme. Un résumé du matin pour le responsable de l’entrepôt envoie une notification par ticket ouvert, chaque jour à 06:00 UTC :

```lua
local export = {}

function export.on_schedule(ctx)
    local ok, result = pcall(document.list, "MaintenanceTicket",
        { status__in = { "reported", "waiting_parts" } })
    if not ok then
        ctx.error("digest failed: " .. tostring(result))
        return
    end
    for _, ticket in ipairs(result.items or {}) do
        local t = util.json_decode(ticket.content or "{}")
        if t.assignee then
            pcall(notification.send, t.assignee, nil, "ticket_open",
                "Ticket still open: " .. tostring(t.problem))
        end
    end
end

return export
```

```yml
hooks:
  - id: morning-digest
    kind: schedule
    schedule: "0 6 * * *"
    script: !read_file hooks/2-morning-digest.lua
```

Les lectures restent dans le domaine propriétaire, donc aucune attribution n’est nécessaire. Voir [Notifications et mentions](/fr/build/model/automation/notifications/) pour les arguments de `notification.send`.

## Dépannage

**Le hook ne se déclenche jamais.**

Vérifiez la source : le domaine doit être réel, le doctype doit exister, et une source étrangère exige une attribution active. Vérifiez aussi `source.events` — un nom d’événement que la source n’émet jamais ne correspond à rien. Un hook tout neuf part aussi du moment présent ; il ne rejoue pas les événements passés.

**L’enregistrement est refusé avec une erreur de hook.**

Le message nomme le hook et le champ. Causes habituelles : un `kind` manquant, un `script` vide, un script qui ne renvoie pas une table, un script sans `on_event` (ou sans `on_schedule` pour un hook planifié), un `id` en double, ou une expression cron avec une macro ou un champ des secondes.

**Le script échoue à l’exécution.**

Le déclenchement journalise l’erreur et continue. Corrigez le script et enregistrez de nouveau le domaine ; rien ne rejoue le déclenchement manqué.

**Ma planification n’a pas tourné pendant une panne.**

Un passage manqué est perdu. L’échéance suivante s’exécute normalement.

## Voir aussi

- [API Lua](/fr/reference/lua-api/) — tous les globaux qu’un script de hook peut appeler.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) — le contrat de livraison complet.
- [Envoyer des webhooks](/fr/build/model/automation/webhooks/) — appeler un système externe sur les mêmes événements.
