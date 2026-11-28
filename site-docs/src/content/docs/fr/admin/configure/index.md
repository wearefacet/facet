---
title: Configurer Facet
description: Choisissez la tâche de configuration — le fichier de configuration, les paramètres système, le courriel, le stockage des fichiers, les devises ou les langues.
type: overview
audience: [admin, operator]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Avant l’arrivée de l’équipe, Facet a besoin de ses réglages : où vont les
fichiers, comment part le courriel, quelles devises les champs monétaires
acceptent. La configuration se divise en deux étages. Un fichier YAML
configure tout le backend et prend effet au démarrage. Un document de
paramètres d’exécution se superpose au fichier et change les clés chaudes —
courriel, rétention, connexion de l’assistant — sans redémarrage.

## Que voulez-vous faire ?

- **Écrire ou modifier le fichier de configuration** →
  [Fichiers de configuration](/fr/admin/configure/configuration-files/).
  Comment le fichier se résout, comment `!env` tient les secrets hors du
  fichier, et quelles clés sont chaudes.
- **Modifier un réglage sans redémarrer** →
  [Paramètres système](/fr/admin/configure/system-settings/). Épingler,
  lire et réinitialiser l’étage d’exécution au-dessus du fichier.
- **Faire aboutir les réinitialisations de mot de passe** →
  [Courriel sortant](/fr/admin/configure/email/). Le relais SMTP, le
  contrôle de production et la sonde de test intégrée.
- **Décider où résident les fichiers téléversés** →
  [Stockage des fichiers](/fr/admin/configure/file-storage/). Un répertoire
  local ou un bucket S3, la limite de 50 MiB et les tâches d’entretien du
  stockage.
- **Maîtriser les champs monétaires** →
  [Devises](/fr/admin/configure/currencies/). Le registre pré-créé, la
  règle d’activité à chaque écriture et les filtres monétaires.
- **Fixer les valeurs par défaut vues par tous** →
  [Langues](/fr/admin/configure/languages/). Le fuseau horaire et la
  langue de l’instance, et comment le choix propre à chaque compte
  l’emporte.

## Toutes les pages de cette section

1. [Fichiers de configuration](/fr/admin/configure/configuration-files/)
2. [Paramètres système](/fr/admin/configure/system-settings/)
3. [Courriel sortant](/fr/admin/configure/email/)
4. [Stockage des fichiers](/fr/admin/configure/file-storage/)
5. [Devises](/fr/admin/configure/currencies/)
6. [Langues](/fr/admin/configure/languages/)

## Voir aussi

- [Passer en production](/fr/admin/install/production/) — la liste de
  contrôle du déploiement, qui se termine par la configuration.
- [Le fonctionnement général](/fr/discover/how-it-works/) — les concepts
  derrière les deux étages.
