---
title: Notifications et mentions
description: Prévenez les personnes depuis vos scripts et mentionnez-les dans les commentaires.
audience: [author, user]
features: [AUT-06]
sidebar:
  order: 24
verified_at: fd345fe3
---

Une notification est un message court dans le menu de la cloche d’une
personne, qui pointe vers un document. Deux chemins les créent : vous tapez
`@` dans un commentaire, ou un script en envoie une. Cette page couvre les
deux, plus l’interrupteur qui les rend muettes.

## Quand l’utiliser

- Une étape de relecture doit avertir son relecteur sans boucle de courriels.
- Un collègue doit savoir qu’on l’a mentionné dans un commentaire.
- Vous lisez les notifications, mais vous voulez que le badge et le panneau
  restent discrets.

## Avant de commencer

- **Pour les mentions @ :** écrivez un commentaire sur n’importe quel
  document. Voir [Commentaires et pièces jointes](/fr/workspace/comments-attachments/).
- **Pour les notifications par script :** vous écrivez du Lua dans un script
  de doctype ou un hook.

## Étapes

### 1. Mentionner une personne

Tapez `@` dans un commentaire et choisissez un nom. La personne reçoit une
notification qui renvoie au document. Se mentionner soi-même ne fait rien, et
une modification ne prévient que les personnes pas encore présentes dans le
texte.

### 2. Activer ou désactiver le panneau

1. Ouvrez **Paramètres** et sélectionnez la section **Notifications**.
2. Activez ou désactivez **Notifications dans l’application**.

La désactivation coupe la cloche, le badge et le panneau en temps réel. Rien
ne se perd : Facet enregistre toujours les notifications, et la réactivation
affiche ce qui est arrivé pendant la coupure.

### 3. Envoyer depuis un script

Les scripts envoient des notifications avec `notification.send`. La fonction
prend un destinataire, un document à pointer et le message. Un appel complet
dans un hook de création :

```lua
local export = {}

function export.create(ctx)
  local ok, sent = pcall(
    notification.send,
    ctx.root.owner_id,
    nil,
    "leave_approved",
    "Your leave request was approved",
    {
      icon = "check",
      body = "Approved by a manager",
      actions = {
        { key = "reopen", label = "Reopen", variant = "primary" }
      }
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
| Destinataire | Un id de compte. Utilisez un champ du document, comme ci-dessus. |
| Document | L’id du document à ouvrir. `nil` désigne le document courant. |
| Type | Une étiquette courte, par exemple `leave_approved`. |
| Titre | Le texte d’une ligne dans le menu de la cloche. |
| Options | Une icône, un texte plus long et des boutons. |

Les boutons exécutent des actions sur le document pointé, sous les droits
propres du lecteur. Une notification ne peut jamais donner un droit que le
lecteur n’a pas.

:::note
Un envoi n’est enregistré qu’après l’enregistrement du changement qui l’a
provoqué. Un changement en échec n’envoie rien.
:::

## Exemple

Le parcours de mention par commentaire, de bout en bout. Marie commente le
contrat `accountancy.Contract.01HQABC3N7P2K5R8WVBN6P3A1YCD` :

```markdown
@Ada Lovelace can you check the totals before Friday?
```

Facet crée une notification pour Ada avec le titre
`Marie Dubois mentioned you on Contract 47`, pointant vers le contrat. Ada
ouvre la cloche, sélectionne l’entrée et se retrouve sur le contrat. L’entrée
reste non lue jusqu’à ce qu’elle la lise ou la rejette.

## Dépannage

**Une mention n’a produit aucune notification.**

Vous vous êtes mentionné, ou le nom n’a pas été choisi dans la liste. Seule
une mention en « chip » envoie ; le texte brut n’envoie rien.

**La cloche ne montre rien de nouveau.**

La préférence est peut-être désactivée, ou la notification était déjà lue.
Vérifiez dans Paramètres → Notifications.

**Mon envoi par script échoue avec une erreur de validation.**

Un argument requis manque ou est trop long. Le titre a une limite de
longueur, et les boutons doivent nommer des actions qui existent sur le
document pointé.

**Les boutons d’une notification ne font rien pour moi.**

L’action exige un droit que votre rôle ne porte pas. Demandez à un
administrateur.

## Voir aussi

- [Doc des notifications sur GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/notifications.md) — le stockage et l’API productrice.
- [Livraison des événements](/fr/concepts/events-delivery/) — comment les
  notifications arrivent à la cloche.
- [Hooks d’événement et planifiés](/fr/build/event-hooks/) — envoyez des
  notifications à chaque changement, pas seulement dans les commentaires.
