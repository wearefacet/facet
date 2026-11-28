---
title: Régler la rétention
description: Fixez la durée de conservation de l’historique des modifications et du contenu des documents supprimés, dans le fichier ou à l’exécution.
audience: [operator]
features: [AUD-05, AUD-06, AUD-07]
sidebar:
  order: 15
verified_at: 008dd880
---

Deux fenêtres bornent les données stockées dans le magasin de documents :
le journal de l’historique des modifications et le contenu des documents
supprimés. Deux passes cron les élaguent une fois par jour. Vous réglez les
fenêtres dans `config.{env}.yml`, et vous pouvez les surcharger à l’exécution.
Le modèle complet — chaque classe de données et sa fenêtre — se trouve dans
[La rétention : quoi et combien de temps](/fr/govern/retention/).

## Quand l’utiliser

Ajustez la rétention quand :

- Vous fixez ou changez `mutations.retention_days` ou
  `tombstone.content_retention_days`.
- Vous avez besoin d’une fenêtre plus courte pour un doctype.
- Vous changez une fenêtre sans redémarrage.

## Avant de commencer

- Une fenêtre de `0` conserve tout : la passe ne fait rien, et le retour
  arrière atteint tout l’historique.
- La profondeur du retour arrière égale la fenêtre des mutations. Les lignes
  que le compactage a fondues ne reviennent pas — voir
  [Revenir en arrière](/fr/govern/rolling-back/).
- Les deux fenêtres acceptent `0` ou plus. Une valeur négative est refusée.

## Étapes

### 1. Fixer les fenêtres dans le fichier de configuration

```yaml
mutations:
  retention_days: 180
  retention_overrides:
    "core.SchematicLayout": 7
  compaction_cron: "45 3 * * *"
  coalesce_window_minutes: 3

tombstone:
  content_retention_days: 30
  prune_cron: "15 4 * * *"
```

| Clé | Valeur par défaut | Signification |
| --- | --- | --- |
| `mutations.retention_days` | `180` | Les lignes d’historique plus anciennes se réduisent à un instantané par document. `0` conserve tout. |
| `mutations.retention_overrides` | — | Une fenêtre par doctype, indexée par le nom qualifié. Fichier uniquement. |
| `mutations.compaction_cron` | `"45 3 * * *"` | Quand tourne la passe de compactage. Fixé au démarrage. |
| `mutations.coalesce_window_minutes` | `3` | Les enregistrements du même acteur dans la fenêtre fusionnent en une seule ligne. `0` désactive. |
| `tombstone.content_retention_days` | `30` | Le contenu des documents supprimés s’efface après ce délai. `0` le garde pour toujours. |
| `tombstone.prune_cron` | `"15 4 * * *"` | Quand tourne la passe d’élagage. Fixé au démarrage. |

### 2. Surcharger une fenêtre à l’exécution

Ouvrez **Configurer → Plateforme → Paramètres** et réglez
`mutations.retention_days` ou `tombstone.content_retention_days`. Chaque passe
lit sa fenêtre au début de son exécution : une surcharge s’applique donc
à partir de la passe quotidienne suivante. Retirez la surcharge pour suivre à

nouveau le fichier.

Les fenêtres par doctype n’ont pas de champ dans les paramètres. Le fichier de
configuration les porte, et un redémarrage applique tout changement.

### 3. Savoir ce que font les passes

La passe de compactage, `mutations.compaction` à 03:45, remplace chaque
mutation plus ancienne que la fenêtre par une seule ligne d’instantané
synthétique par document. Le document lui-même ne change jamais, et aucun
événement n’est émis. Un document en tombstone garde toujours son delete final
et la ligne qui le précède : une restauration reste donc possible.

La passe d’élagage, `tombstone.content_prune` à 04:15, efface le contenu
`content`, `links` et `search` des tombstones au-del à de la fenêtre, par lots
bornés. Le libellé reste : les vues d’audit peuvent toujours nommer la
ligne supprimée.

### 4. Connaître les cas limites

- Une cible de retour arrière plus ancienne que la fenêtre répond `404`, et le
  corps nomme la fenêtre effective du doctype.
- La fusion à l’écriture réunit les enregistrements du même acteur dans
  `coalesce_window_minutes` en une seule ligne. L’ancien id répond `404` dans
  la fenêtre, et l’historique montre un petit écart dans l’ordre des lignes.
- Une fenêtre de base de `0` désactive aussi les fenêtres par doctype pour
  cette passe.
- La fenêtre de rattrapage des webhooks, `webhook.reconcile_window_hours`,
  doit rester en dessous de `jobs.retention_days`. Le démarrage refuse une
  configuration qui enfreint la règle — voir
  [Tâches en arrière-plan et cron](/fr/operate/jobs-cron/).

## Exemple

Surchargez une fenêtre d’historique de 90 jours à l’exécution, puis rendez-la
au fichier :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mutations": {"retention_days": 90}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

La passe de compactage suivante, au prochain `03:45` UTC, applique la
surcharge. La page des paramètres marque le champ du badge
« surcharge ». Retirez la surcharge avec un `null` explicite, dans
le même corps PATCH.

## Dépannage

**Un retour arrière répond `404` et nomme une fenêtre.**

La cible est plus ancienne que la fenêtre. Voir
[Revenir en arrière](/fr/govern/rolling-back/).

**La table des mutations grossit sans fin.**

La fenêtre vaut `0` : la passe ne fait rien. C’est un choix valable :
la profondeur du retour arrière devient l’historique complet. Fixez une
fenêtre pour relancer l’élagage.

**Une fenêtre par doctype reste sans effet.**

La fenêtre de base vaut `0` — un `0` côté fichier ou une surcharge à

l’exécution. Les fenêtres par doctype ne s’appliquent pas tant que la passe
est désactivée. Fixez la fenêtre de base à un nombre de jours.

**L’historique montre un écart dans l’ordre des lignes.**

La fusion à l’écriture a réuni des enregistrements du même acteur. La ligne
suivante porte le changement composé. C’est normal.

**Un changement de configuration reste sans effet.**

Le chemin porte une surcharge sur le document des paramètres. Retirez-la —
voir [Paramètres système](/fr/operate/system-settings/).

## Voir aussi

- [La rétention : quoi et combien de temps](/fr/govern/retention/) — le
  modèle : chaque classe de données et sa fenêtre.
- [Revenir en arrière](/fr/govern/rolling-back/) — la limite de profondeur que
  la fenêtre crée.
- [Le journal des mutations](/fr/concepts/mutation-log/) — ce que le journal
  enregistre.
- [Paramètres système](/fr/operate/system-settings/) — le fonctionnement des
  surcharges à l’exécution.
- [Tâches en arrière-plan et cron](/fr/operate/jobs-cron/) — les calendriers
  et la règle de rétention des tâches.
- Internes sur GitHub :
  [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md),
  [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
