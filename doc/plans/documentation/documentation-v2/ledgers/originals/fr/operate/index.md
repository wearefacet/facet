---
title: Opérer
description: "Faites tourner Facet en production : déployez en conteneurs, configurez, surveillez, et mettez à niveau."
audience: [operator]
features: []
sidebar:
  order: 0
verified_at: 008dd880
---

Cette section s’adresse aux opérateurs qui font tourner Facet pour leur
organisation. Elle couvre les prérequis système, le déploiement en
conteneurs, la configuration, le stockage, l’envoi des mails, les tâches
d’arrière-plan, les contrôles de santé et les métriques, les devises, la
rétention, les mises à niveau, et la localisation.

## Déployer et configurer

- [Prérequis système et topologie](/fr/operate/system-requirements/) — ce
  qu’exige une machine hôte et comment les services se connectent.
- [Déploiement en conteneurs](/fr/operate/containers-tls/) — les images de
  version, le montage de la configuration, et la terminaison TLS Caddy.
- [Déployer en production](/fr/operate/production/) — le guide Docker
  Compose à copier-coller.
- [Fichiers de configuration](/fr/operate/configuration-files/) — un seul
  fichier YAML configure le backend ; les secrets s’injectent avec `!env`.
- [Paramètres système](/fr/operate/system-settings/) — changez les réglages
  de la plateforme à chaud, avec le fichier de configuration en secours.
- [Amorçage et tâches CLI](/fr/operate/bootstrap-cli/) — premier
  déploiement, comptes, récupération après verrouillage, et commandes de
  maintenance.
- [Envoi des mails](/fr/operate/email/) — la configuration SMTP, le
  contrôle de production, et les changements à chaud.
- [Stockage de fichiers : local ou S3](/fr/operate/file-storage/) —
  le magasin d’artefacts, ses réglages, et ses tâches d’entretien.
- [Configurer l’assistant](/fr/operate/assistant-config/) — connectez un
  fournisseur compatible OpenAI et ajustez les tours d’échange.
- [Migrations de base de données](/fr/operate/migrations/) — application et
  retour arrière, et les règles UTC et append-only.
- [Index gérés](/fr/operate/indexes/) — surveillez la santé des index et
  relancez les constructions en échec.

## Faire tourner et maintenir

- [Tâches d’arrière-plan et cron](/fr/operate/jobs-cron/) — la file des
  tâches, les relances et les baux, et les huit passages planifiés.
- [Contrôles de santé, métriques, tracing, journaux](/fr/operate/health-metrics-logs/) —
  les sondes, le catalogue de métriques, OpenTelemetry, et la configuration
  des journaux.
- [Devises et montants](/fr/operate/currencies/) — gérez la liste des
  devises et voyez comment les montants se stockent et se filtrent.
- [Réglage de la rétention](/fr/operate/retention-tuning/) — fixez les
  fenêtres d’historique et de tombstones, dans le fichier ou à chaud.
- [Mises à niveau et arrêt propre](/fr/operate/upgrades-shutdown/) — le
  guide de mise en production et la séquence d’arrêt propre.
- [Localisation](/fr/operate/localization/) — les valeurs par défaut de
  fuseau horaire et de langue pour l’instance, et les réglages par compte.
