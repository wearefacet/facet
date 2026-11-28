---
type: how-to
title: Notifications et mentions
description: Prévenez des personnes depuis vos scripts et mentionnez-les dans les commentaires.
audience: [author, user]
features: [AUT-06]
sidebar:
  order: 2
verified_at: eee55a2
---

Un ticket de maintenance reste sans responsable pendant deux jours parce que personne ne le savait. Une notification est un message court dans le menu de la cloche d’une personne ; il pointe vers un document. Deux chemins en créent : vous tapez `@` dans un commentaire, ou un script en envoie. Cette page couvre les deux chemins, avec l’interrupteur qui les rend silencieux. Le chemin script demande un appel Lua ; le chemin mention n’exige aucun code.

## Quand l’utiliser

- Une étape de revue doit prévenir son réviseur sans boucle de courriel.
- Un collègue doit savoir qu’une mention le vise dans un commentaire.
- Vous lisez les notifications mais voulez que le badge et le panneau restent silencieux.

## Avant de commencer

- **Pour les @mentions :** vous écrivez un commentaire sur n’importe quel document — voir [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/).
- **Pour les notifications par script :** vous écrivez du Lua dans un script de doctype ou un hook.

## Mentionner une personne

Tapez `@` dans un commentaire et choisissez un nom dans la liste. La personne reçoit une notification qui ramène au document. Trois règles gardent le silence :

- Se mentionner soi-même n’envoie rien.
- Seule une mention choisie envoie ; un texte simple avec un `@` ne le fait pas.
- Une modification ne notifie que les personnes nouvelles dans le texte — une mention conservée à travers une modification reste silencieuse.

## Activer ou désactiver le panneau

1. Ouvrez **Paramètres** et sélectionnez la section **Notifications**.
2. Activez ou désactivez **Notifications dans l’application**.

Hors service, la cloche, le badge et le panneau en direct se taisent. Rien n’est perdu : Facet enregistre toujours les notifications, et la réactivation montre ce qui est arrivé pendant le silence.

## Envoyer depuis un script

Les scripts envoient des notifications avec `notification.send`. La fonction prend un destinataire, un document à pointer et le message. Un appel complet dans un hook create d’un ticket de maintenance Brightwater :

```lua
local export = {}

function export.create(ctx)
  if ctx.actor == nil then return end
  if not ctx.root.assignee then return end
  local ok, sent = pcall(
    notification.send,
    ctx.root.assignee,
    nil,
    "ticket_assigned",
    "A ticket was assigned to you",
    {
      icon = "wrench",
      body = "Reported by " .. tostring(ctx.actor_id)
    }
  )
  if not ok then
    ctx.error("Failed to notify: " .. tostring(sent))
  end
end

return export
```

| Argument | Signification |
| --- | --- |
| Destinataire | Un identifiant de compte. Utilisez un champ du document, comme ci-dessus. |
| Document | L’identifiant qualifié du document à ouvrir. `nil` désigne le document courant. |
| Type | Une étiquette courte, par exemple `ticket_assigned`. |
| Titre | Le texte d’une ligne dans le menu de la cloche. |
| Options | Une icône, un corps plus long, des données structurées et des boutons. |

Un bouton est un descripteur d’action — `{ key = "confirm", label = "Confirm", variant = "primary" }` — et il doit nommer une action qui existe sur le document pointé. Trois règles bornent l’envoi :

- **L’envoi attend l’écriture.** Facet enregistre la notification seulement après l’enregistrement du changement qui l’a provoquée. Un changement qui échoue n’envoie rien.
- **Les boutons s’exécutent avec les droits du lecteur.** Un bouton nomme une action sur le document pointé ; son exécution passe par la même vérification que le menu du document. Une notification ne peut jamais conférer un droit que le lecteur n’a pas.
- **Un bouton se déclenche une fois.** La première action réussie ferme tous les boutons de cette notification ; une seconde pression répond `409`.

Enveloppez l’appel dans `pcall` quand un échec est acceptable ; un envoi mal formé lève une erreur Lua au moment de l’envoi.

## Exemple

Le flux de mention par commentaire, de bout en bout, sur l’exemple Brightwater. Lucía commente le ticket de maintenance `MT-2026-0004` :

```markdown
@Tom Aaland can you order the contact cleaner today?
```

Facet crée une notification pour Tom, qui pointe vers le ticket. Le titre affiche *Lucía Ferrer mentioned you* — le ticket n’a pas de champ `name`, `title` ou `label`, donc le libellé hôte est abandonné plutôt que deviné. Sur un doctype qui en a un, le titre le porte : *Lucía Ferrer mentioned you on Main tent 10x15*. Tom ouvre la cloche, sélectionne l’entrée et atterrit sur le ticket. L’entrée reste non lue tant qu’il ne la lit pas ou ne l’écarte pas.

## Dépannage

**Une mention n’a produit aucune notification.**

Vous vous êtes mentionné vous-même, ou le nom a été tapé comme texte simple au lieu d’être choisi dans la liste. Seule une mention en pastille envoie.

**La cloche ne montre rien de nouveau.**

La préférence est peut-être désactivée, ou la notification a déjà été lue. Vérifiez **Paramètres → Notifications**.

**Mon envoi par script échoue avec une erreur de validation.**

Un argument requis manque ou est trop long : le titre accepte au plus 256 caractères, et les boutons doivent nommer des actions qui existent sur le document pointé.

**Les boutons d’une notification ne font rien pour moi.**

L’action exige un droit que votre rôle ne porte pas, ou la notification a déjà consommé sa seule action. Pour le premier cas, demandez à un administrateur ; attendez-vous à `409` pour le second.

## Voir aussi

- [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) — où vivent les mentions.
- [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) — envoyer des notifications à chaque changement, pas seulement dans les commentaires.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) — comment les notifications arrivent à la cloche.
- Internes sur GitHub : [notifications.md](https://github.com/wearefacet/facet/blob/main/doc/backend/notifications.md).
