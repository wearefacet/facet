---
title: Clés de réglage de compte
description: Chaque clé de réglage de compte, avec son type et sa valeur par défaut.
audience: [operator, admin]
features: [PLT-17]
sidebar:
  order: 16
verified_at: 008dd880
---

> Généré depuis `src/settings/keys.cr` par `make gen-docs-account-settings`. Ne modifiez pas ce fichier à la main.

Cette page sert à trouver une clé, son type et sa valeur par défaut. Les réglages de compte sont des préférences propres à chaque compte. Le service les stocke sous forme de paires `(app, key)` et refuse toute paire que ce registre ne liste pas.

Le tableau liste chaque clé enregistrée, avec son type et sa valeur par défaut.

| Clé | Type | Défaut | Rôle |
|---|---|---|---|
| `core.language` | string | "en" | Code de langue pour l'interface du compte. Valeurs autorisées : en, fr. |
| `core.pinned_collection_views` | array | [] | Vues de collection que le compte épingle dans les listes de doctypes. |
| `core.pinned_doctypes` | array | [] | Noms de doctypes qualifiés que le compte épingle en haut de la barre latérale. |
| `core.show_welcome` | bool | true | Rejoue la visite de bienvenue au premier lancement quand vrai ; la visite écrit faux quand on la ferme. |
| `core.timezone` | string | "UTC" | Fuseau horaire IANA dans lequel s'affichent les dates et heures du compte. |
| `notifications.in_app` | bool | true | Commande la diffusion des notifications côté client : cloche, badge et abonnement en direct. |

Deux clés portent un palier serveur avant leur défaut de registre. Un compte sans valeur propre suit les réglages système de l'instance :

- `core.language` suit `localization.default_language`.
- `core.timezone` suit `localization.default_timezone`.

## Voir aussi

- [/fr/use/account/](/fr/use/account/)
- [/fr/admin/configure/system-settings/](/fr/admin/configure/system-settings/)