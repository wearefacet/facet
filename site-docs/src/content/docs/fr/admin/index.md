---
title: Gouverner l’accès
description: "Comptes, rôles, périmètres, audit et retour arrière : contrôlez qui voit et qui change les données."
audience: [admin]
features: []
sidebar:
  order: 0
verified_at: fd345fe3
---

Cette section s’adresse aux administrateurs. Elle couvre les comptes, les
rôles et les lignes de permission, les périmètres de lignes, la visibilité des
champs, les politiques de connexion, l’accès machine, la piste d’audit, le
retour arrière, la rétention, et les règles pour les applications et
l’assistant.

Commencez par les pages d’identité, puis les pages d’autorisation, puis les
pages d’assurance. Chaque page se lit seule ; les liens croisés
complètent le modèle.

## Identité

- [Gérer les comptes](/fr/admin/people/accounts/) — le document compte, le
  cycle des statuts, le premier identifiant, la suppression et la restauration.
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — la
  grammaire des lignes, les actions nommées, et le garde-fou qui borne chaque
  écriture de rôle.
- [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) —
  placer des rôles sur les comptes, et comment un seul rôle est élu par
  requête.
- [Imposer le MFA](/fr/admin/people/mfa/) — le facteur TOTP, les deux
  niveaux d’application, et la récupération.
- [Le SSO avec OIDC](/fr/admin/people/sso/) — les documents fournisseurs, le
  provisionnement JIT, et le mode SSO seul.
- [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/) —
  durées de vie des tokens, rotation, et limitation des connexions.
- [Accès machine : clés d’API](/fr/admin/apps-access/api-keys/) — des clés
  statiques épinglées à un compte et un rôle.

## Autorisation

- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — resserrer une ligne de
  permission du doctype entier aux lignes qui correspondent.
- [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/) —
  masquer des champs par rôle, en lecture, en écriture et dans le journal
  d’audit.

## Assurance

- [Auditer l’activité](/fr/admin/history/audit/) — lire le journal des
  mutations et le journal des connexions.
- [Revenir en arrière](/fr/admin/history/roll-back/) — annuler jusqu’à une
  mutation antérieure, restaurer une suppression, et les limites.
- [La rétention](/fr/admin/history/retention/) — ce que garde chaque classe de
  données, et pendant combien de temps.
- [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/) — borner ce
  qu’une application externe peut tenter.
- [Gouverner l’assistant](/fr/admin/assistant/govern/) — disponibilité,
  budgets de tokens, instructions, et comportement des outils.

## Voir aussi

- [Sécurité et gouvernance](/fr/discover/security/) — le résumé pour
  l’évaluation de ce modèle.
- [Rôles, niveaux et garde-fou d’autorité](/fr/admin/people/who-can-change-roles/) —
  le concept derrière le garde-fou.
