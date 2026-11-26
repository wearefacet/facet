---
title: "La rétention : quoi et combien de temps"
description: "Voyez ce que Facet garde pour les documents, les mutations, les événements, les sessions et les fichiers, et où se règle chaque fenêtre."
audience: [admin, evaluator]
features: [AUD-05, AUD-06, AUD-07]
sidebar:
  order: 12
verified_at: fd345fe3
---

Facet garde plusieurs classes de données, avec des durées de vie
différentes. PostgreSQL porte l’état durable. Redis porte l’état de courte
durée. Cette page liste ce que chaque classe garde, la fenêtre qui la
borne, et où vous réglez la fenêtre.

## Quand l’utiliser

- Vous rédigez la politique de rétention des données de votre organisation.
- Vous réglez les fenêtres d’un déploiement.
- Vous répondez à la profondeur que peut atteindre un retour arrière.

## Explication

### Ce que chaque classe garde

| Classe de données    | Ce qui est gardé                                                                                       | Combien de temps                                                                                      |
| --------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Documents             | L’état courant de chaque document vivant.                                                                | Tant que le document vit. Une suppression fait un tombstone ; elle ne retire pas la ligne.                |
| Mutations             | Le journal complet des changements de chaque document.                                                    | `mutations.retention_days`, 180 par défaut. `0` garde tout. Les lignes plus anciennes se replient en une ligne d’instantané par document. |
| Mises à jour fusionnées | Les mises à jour du même acteur et du même canal, à l’intérieur de `mutations.coalesce_window_minutes` (3 par défaut), se replient en une ligne. | La ligne repliée remplace l’ancienne. L’ancien id répond `404` à l’intérieur de la fenêtre. |
| Tombstones            | Un document supprimé garde son contenu, ses liens, et son texte de recherche. Le libellé et les métadonnées restent. | La purge efface le payload après `tombstone.content_retention_days`, 30 par défaut. `0` le garde pour toujours. |
| Événements            | Chaque flux Redis garde les événements récents pour les réactions.                                        | Élagué à `event.maxlen`, 1 000 000 entrées par shard par défaut. La livraison est au plus une fois ; PostgreSQL porte l’état durable. |
| Jobs et appels webhook | Les lignes de jobs d’arrière-plan finis et les lignes d’appels webhook.                                   | `jobs.retention_days`, 30 par défaut.                                                                     |
| Sessions et tokens    | Sessions de refresh, tokens d’accès, défis MFA, liens d’identifiant.                                      | Session de refresh : 14 jours. Token d’accès : 15 minutes. Défi MFA : 5 minutes. Liens d’identifiant : 24 heures. La déconnexion efface la session. |
| Fichiers              | Les octets téléversés et leurs métadonnées.                                                               | Conservés tant qu’un document vivant les possède. Les fichiers sans propriétaire sont purgés après `artifact.prune_after_days`, 30 par défaut, quand aucune référence récente ne les nomme. `0` garde tout. |
| Événements de connexion | Les documents `iam.LoginEvent` enregistrent chaque événement d’authentification.                        | Ils suivent les fenêtres de document et de mutation ci-dessus.                                            |

### Notes par classe

**Mutations.** La passe de compactage quotidienne, par défaut à 03:45,
remplace chaque mutation plus ancienne que la fenêtre par une ligne
d’instantané synthétique par document. La ligne d’instantané garde
l’horodatage d’origine et garde l’ordre des lignes contigu. Le document
lui-même ne change jamais, et aucun événement n’est émis. Un document
tombstoné garde toujours son delete final et la ligne avant lui, si bien
qu’une restauration reste atteignable. Une carte de surcharges par doctype
peut raccourcir la fenêtre pour des doctypes isolés.

**Fusion à l’écriture.** Quand un compte enregistre le même document deux
fois à l’intérieur de la fenêtre, par le même canal, Facet replie les deux
mises à jour en une ligne avec un id neuf. La ligne porte un changement
composé. L’historique montre un petit trou dans l’ordre des lignes où des
lignes se sont pliées. Un retour arrière vers la ligne repliée restaure
l’état final.

**Tombstones.** Le payload conservé laisse Facet vérifier les périmètres de
lignes sur les événements de suppression. Le payload ne fuit jamais dans
les listes, les résultats de recherche, ou les instantanés : chaque filtre
de liste ne vise que les lignes vivantes. Le libellé reste, si bien que les
vues d’audit peuvent nommer un document supprimé.

**Événements.** Facet traite la livraison des événements comme au plus une
fois, par décision. Un événement perdu est une réaction perdue, et presque
chaque réaction a un chemin de réparation. La vérification de retard
avertit avant qu’un consommateur lent n’atteigne le point d’élagage. Le
réconciliateur de webhooks rejoue les mises en file de webhooks manquées
depuis le journal des mutations à l’intérieur de
`webhook.reconcile_window_hours`, 24 par défaut. Cette fenêtre doit rester
en dessous de `jobs.retention_days`.

**Sessions.** Les durées de vie viennent des clés de configuration
`iam.jwt.refresh_token_ttl` (1 209 600 secondes),
`iam.jwt.access_token_ttl` (900 secondes), et
`iam.change_password_expiration` (86 400 secondes) pour les liens de
réinitialisation de mot de passe, d’invitation, et de premier identifiant.
Le défi MFA vit 5 minutes. Une perte complète de Redis ne fait que forcer
chacun à se reconnecter.

**Fichiers.** Un fichier qu’un document vivant possède reste. Les lignes
propriétaires ne disparaissent qu’avec leur document, leur domaine, ou le
fichier lui-même. Un fichier sans propriétaire vivant est purgé après la
fenêtre, sauf si une référence à l’intérieur de la fenêtre le nomme encore.

:::caution[La fenêtre des mutations borne la profondeur du retour arrière]
Une cible de retour arrière plus ancienne que la fenêtre répond `404`.
Élargir la fenêtre ne ramène pas les lignes compactées — voir
[Revenir en arrière](/fr/admin/history/roll-back/).
:::

## Étapes

### Régler les fenêtres

1. Modifiez `config.<environment>.yml`. Le fichier est la source de vérité
   pour chaque fenêtre. L’exemple ci-dessous montre les clés de rétention
   avec leurs défauts.
2. Pour changer une fenêtre sans redémarrage, épinglez-la à l’exécution.
   Ouvrez **Configurer → Plateforme → Paramètres** et réglez
   `mutations.retention_days` ou `tombstone.content_retention_days`. Une
   épingle s’applique à partir de la prochaine passe quotidienne. Une
   épingle de `0` signifie garder pour toujours.
3. Les surcharges par doctype ne passent que par le fichier. La page des
   paramètres ne les porte pas.

:::tip
La page des paramètres marque chaque valeur épinglée avec un badge
« surcharge ». Retirez l’épingle pour suivre de nouveau le fichier.
:::

## Exemple

```yaml
# Clés de rétention avec leurs défauts.
mutations:
  retention_days: 180
  retention_overrides:
    "core.SchematicLayout": 7
  compaction_cron: "45 3 * * *"
  coalesce_window_minutes: 3

tombstone:
  content_retention_days: 30
  prune_cron: "15 4 * * *"

event:
  maxlen: 1000000

jobs:
  retention_days: 30

artifact:
  prune_after_days: 30
```

## Dépannage

### Le journal des mutations continue de grossir

La fenêtre est `0`, ce qui désactive la passe. Vérifiez la valeur effective
sur la page des paramètres.

### Un retour arrière répond `404` et nomme une fenêtre

La cible est plus ancienne que la fenêtre — voir
[Revenir en arrière](/fr/admin/history/roll-back/).

### L’historique montre un trou dans l’ordre des lignes

La fusion à l’écriture a replié des enregistrements du même acteur. La
ligne la plus récente porte le changement composé.

## Voir aussi

- [Revenir en arrière](/fr/admin/history/roll-back/) — la limite que crée la
  fenêtre.
- [Auditer l’activité](/fr/admin/history/audit/) — lire le journal que
  la fenêtre borne.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) et
  [La livraison des événements](/fr/admin/under-the-hood/events-and-delivery/) — les
  concepts.
- [Déployer en production](/fr/admin/install/production/) — où se trouve le
  fichier de configuration.
- Internes sur GitHub :
  [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md),
  [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
