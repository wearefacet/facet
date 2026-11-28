---
type: reference
title: Glossaire
description: Une définition courte par terme employé dans la documentation Facet, par ordre alphabétique.
audience: [evaluator, user, author, admin, developer, operator]
features: []
sidebar:
  order: 1
verified_at: eee55a2
---

Facet garde un seul sens par mot. Les entrées ci-dessous définissent d’abord
les termes produit que vous croisez sur chaque page, puis les termes des pages
techniques. Chaque entrée donne la définition simple, les autres noms
possibles, et la page qui explique le terme en détail.

## Termes produit

**Action** — Une opération nommée qu’un doctype déclare, comme `approve`.
L’appelant la déclenche par un bouton ou par l’API, et son exécution entre
dans l’historique comme tout autre changement. Autre nom : action nommée.
→ [Ajouter des actions à un doctype](/fr/build/model/behaviour/named-actions/)

**API key** — Un token secret qui authentifie un script ou une app auprès de
l’API. Chaque compte crée et révoque ses clés dans les paramètres ; les apps
portent leurs propres clés, que les administrateurs gèrent dans
l’administration.
→ [Clés d’API](/fr/admin/apps-access/api-keys/)

**App** — Un programme externe enregistré dans Facet qui appelle l’API pour
ses utilisateurs. Sa portée est l’intersection des droits de l’utilisateur et
des attributions de l’app.
→ [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/)

**Assistant** — Le panneau de chat intégré à Facet. L’assistant de l’espace
de travail répond aux questions et modifie des documents ; l’assistant du
créateur de domaines conçoit des doctypes, des vues et des fixtures à partir
d’une description.
→ [Interroger l’assistant](/fr/use/assistant/), [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/)

**Backlink** (lien entrant) — La trace d’un autre document qui référence
celui-ci. La page détail les liste sous « Référencé par ».
→ [Références et liens](/fr/build/model/relations/references-links/)

**Builder** — L’éditeur intégré où les auteurs créent des domaines, des
doctypes et des vues sans fichier de code.
→ [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/)

**Bundle** — Un dossier de fichiers de domaine (YAML, avec des sidecars Lua
pour les scripts) qui définit un domaine, prêt pour le contrôle de version.
Déployez-le avec la CLI ou modifiez-le dans le watcher de domaine.
→ [Déplacer des domaines avec des bundles](/fr/build/model/bundles/)

**Collection view** — Une façon enregistrée de lister les enregistrements
d’un doctype : tableau, kanban, calendrier ou grille, avec ses filtres
et ses colonnes. Une vue est personnelle ou partagée.
→ [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/)

**Document** — Un enregistrement : un corps JSON avec un id unique, une
version courante, et l’historique complet des changements.
→ [Fonctionnement des documents](/fr/discover/how-it-works/documents/)

**Doctype** — Un type d’enregistrement typé dans un domaine, comme
`hr.Employee`. Sa définition déclare les champs, les actions et les
périmètres.
→ [Concevoir des doctypes](/fr/build/model/data/design-doctypes/)

**Domain** (domaine) — Un espace de noms pour un secteur métier, comme `hr`
ou `sales`. Il regroupe des doctypes et borne les droits et la portabilité.
→ [Domaines et isolement](/fr/discover/how-it-works/domains/)

**Draft** (brouillon) — Un domaine de brouillon jetable, dont l’id commence
par `_`, où vous itérez sur les doctypes avant de les publier dans le domaine
réel.
→ [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/)

**Field** — Un emplacement typé dans un doctype, comme `email` avec le type
`string`. Le type décide comment la valeur est stockée, vérifiée et affichée.
→ [Types de champs](/fr/build/model/data/field-types/)

**Field tag** (étiquette de champ) — Une étiquette posée sur un champ qui
contrôle qui le voit. Un rôle doit porter l’étiquette pour lire ou écrire le
champ.
→ [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/)

**Grant** (attribution) — Un consentement explicite. L’attribution d’une app
dit ce qu’une app externe peut faire ; une attribution de domaine laisse un
domaine lire des ressources nommées d’un autre.
→ [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/), [Partager entre domaines](/fr/build/model/relations/across-domains/)

**History** — La liste complète des changements d’un document : qui a changé
quoi, quand, et pourquoi. Vous pouvez annuler jusqu’à n’importe quel point.
→ [Historique et retour arrière](/fr/use/documents/history-undo/)

**Hook** — Un script Lua que Facet exécute à un point du cycle de vie, par
exemple avant un enregistrement. Il peut vérifier, modifier ou refuser le
changement. Autre nom : event hook (quand il s’exécute sur le bus
d’événements).
→ [Scripts et garde-fous](/fr/build/model/behaviour/scripts-and-guards/), [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/)

**Permission** — Ce qu’un rôle peut faire : lire, créer, mettre à jour,
supprimer ou exécuter une action, sur un chemin de doctype. Un rôle détient
une liste de lignes de permission.
→ [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)

**Permission line** (ligne de permission) — La forme JSON d’une permission
dans le document d’un rôle : `action`, `on`, et les `scope` et `except`
facultatifs.
→ [Syntaxe des lignes de permission](/fr/reference/permission-syntax/)

**Publish** (publication) — Le passage d’un domaine de brouillon vérifié au
domaine réel. Après la publication, les utilisateurs voient les nouveaux
doctypes.
→ [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/)

**Retention** (rétention) — Les règles qui décident combien de temps Facet
garde l’historique, les pierres tombales et les lignes de jobs avant de les
nettoyer.
→ [Rétention : ce qui est gardé](/fr/admin/history/retention/)

**Rollback** (retour arrière) — La restauration d’un document à un point
antérieur de son historique. L’espace de travail la présente comme une
annulation.
→ [Historique et retour arrière](/fr/use/documents/history-undo/)

**Role** (rôle) — L’unité de droits qu’une personne ou une app détient. Un
rôle porte des lignes de permission, des étiquettes de champ visibles, et un
niveau. Chacun agit sous un seul rôle à la fois.
→ [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)

**Row scope** (périmètre de lignes) — Une règle enregistrée qui décide
quelles lignes d’un doctype une permission atteint, par exemple « les lignes
que je possède ». Autre nom : périmètre nommé.
→ [Les périmètres de lignes](/fr/admin/people/row-scopes/)

**Service account** — Une identité de machine qui se connecte avec une clé
d’API au lieu d’un mot de passe. Une app backend en utilise une pour agir
avec un rôle fixé.
→ [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/)

**Sidecar** — Un doctype qui s’attache à n’importe quel document par un champ
référence, comme un commentaire ou une pièce jointe. Autre nom : commentaires
et pièces jointes (interface).
→ [Commentaires et pièces jointes](/fr/build/model/relations/comments-attachments/)

**View template** (modèle de vue) — Le modèle enregistré qui définit le rendu
de la page détail d’un document : l’en-tête, les onglets, les champs et les
tables de relations.
→ [Concevoir les pages document](/fr/build/model/views/document-pages/)

**Webhook** — Un enregistrement sortant qui livre un message d’événement
signé à votre URL quand un doctype change.
→ [Envoyer des webhooks](/fr/build/model/automation/webhooks/)

**Workspace** (espace de travail) — L’application web où l’on travaille avec
des documents : listes, tableaux, calendriers, formulaires, et l’assistant.
→ [L’espace de travail](/fr/use/)

## Termes du moteur

Ces termes décrivent le fonctionnement du moteur. Ils servent dans les pages
techniques et dans les sections « How it works » ; les pages du quotidien le
disent en mots simples.

**At-most-once** — Une livraison d’événements qui peut perdre un événement en
cas de défaillance, mais qui ne le livre jamais deux fois. Le job de
réconciliation des webhooks répare une perte dans sa fenêtre. *Utilisé dans
les pages techniques.*
→ [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/)

**Auth context** (contexte d’authentification) — L’ensemble identité et
droits d’une requête : qui appelle, l’unique rôle élu, et l’attribution de
l’app quand une app appelle. Autre nom : `AuthContext` (dans le code).
*Utilisé dans les pages techniques.*
→ [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/)

**Cause chain** — La trace de la raison d’un changement. Chaque ligne du
journal des mutations porte sa cause directe ; suivre les liens révèle toute
la piste. *Utilisé dans les pages techniques.*
→ [Voir qui a fait quoi](/fr/admin/history/audit/)

**Coalescing** (fusion à l’écriture) — La fusion des mises à jour d’un
document faites par le même acteur sur le même canal, dans une courte
fenêtre, en une seule ligne du journal des mutations. *Utilisé dans les
pages techniques.*
→ [Le journal des mutations](/fr/admin/under-the-hood/change-log/)

**Compaction** (compactage) — Le job qui remplace les lignes du journal des
mutations plus vieilles que la fenêtre de rétention par une seule ligne de
synthèse. *Utilisé dans les pages techniques.*
→ [Rétention : ce qui est gardé](/fr/admin/history/retention/)

**Consumer group** — Une position de lecture nommée sur le flux d’événements.
Chaque groupe lit à son rythme et garde sa propre place. *Utilisé dans les
pages techniques.*
→ [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/)

**DPoP** — Une liaison de token qui prouve que chaque requête porte la clé
privée de l’app. Un token volé, à lui seul, ne peut pas appeler l’API.
*Utilisé dans les pages techniques.*
→ [Lier les tokens à votre app (DPoP)](/fr/build/apps/connect/dpop/)

**Elected role** (rôle élu) — L’unique rôle sous lequel un appelant agit pour
une requête. Les rôles ne fusionnent jamais. *Utilisé dans les pages
techniques.*
→ [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/)

**Effective scope** (périmètre effectif) — Les droits qu’un appelant possède
réellement, résolus à chaque requête : les périmètres du rôle se déploient
contre la définition réelle, et les attributions de l’app plafonnent le
résultat. *Utilisé dans les pages techniques.*
→ [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/)

**Enforcer** (contrôleur) — Le code qui vérifie une règle à chaque requête :
il refuse la classe d’opération avec un `403`, ou restreint les lignes.
*Utilisé dans les pages techniques.*
→ [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)

**ETag** — Le tampon de version d’un document ou d’une liste, envoyé dans les
en-têtes de réponse. Un client le renvoie pour mettre à jour sans risque ou
pour éviter un téléchargement. *Utilisé dans les pages techniques.*
→ [API REST](/fr/reference/rest-api/)

**Intersection (∩)** — La règle selon laquelle une app ne peut jamais faire
plus que ce que l’utilisateur et l’app ont tous deux le droit de faire.
S’écrit `grants ∩ roles`. *Utilisé dans les pages techniques.*
→ [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/)

**JSONB** — Le type de colonne PostgreSQL qui stocke un document JSON. Facet
stocke chaque corps de document dans une colonne de ce type. *Utilisé dans
les pages techniques.*
→ [Fonctionnement des documents](/fr/discover/how-it-works/documents/)

**Lazy migration** — La mise à jour d’un document ancien vers la structure
actuelle du doctype, la prochaine fois que quelqu’un le lit ou l’écrit.
*Utilisé dans les pages techniques.*
→ [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/)

**Lease** — La fenêtre de temps pendant laquelle un worker détient un job en
arrière-plan, si bien que les autres workers le laissent tranquille.
*Utilisé dans les pages techniques.*
→ [Tâches de fond et cron](/fr/admin/keep-running/jobs-cron/)

**Metadata gate** — La règle qui ne livre une définition de doctype ou de
domaine qu’aux appelants qui détiennent une attribution sur ce que la
définition décrit, et cache le reste. Grâce à elle, un rôle à périmètre
restreint continue de naviguer. *Utilisé dans les pages techniques.*
→ [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)

**Mutation** — Une ligne du journal des mutations : qui a changé quel
document, comment, quand, et pourquoi. Création, mise à jour, suppression et
instantané sont des mutations. *Utilisé dans les pages techniques.*
→ [Le journal des mutations](/fr/admin/under-the-hood/change-log/)

**Mutation log** (journal des mutations) — L’enregistrement append-only de
chaque changement, dans l’ordre. L’historique le lit ; l’état courant du
document vit en dehors. Autre nom : « Historique » (interface). *Utilisé dans
les pages techniques.*
→ [Le journal des mutations](/fr/admin/under-the-hood/change-log/)

**PKCE** — La protection d’échange de code du flux de connexion OAuth 2.1.
Elle empêche l’utilisation d’un code d’autorisation intercepté. *Utilisé dans
les pages techniques.*
→ [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/)

**Principal** — L’identité qui agit : une personne, une app, ou le système.
*Utilisé dans les pages techniques.*
→ [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)

**Projection** — La version courante d’un document : son contenu, son
libellé, son texte de recherche et ses liens entrants. Les lectures passent
par les projections ; le journal stocke l’historique. *Utilisé dans les pages
techniques.*
→ [Fonctionnement des documents](/fr/discover/how-it-works/documents/)

**Re-projection** — La reconstruction de la version courante d’un document
après un changement de la définition de son doctype. *Utilisé dans les pages
techniques.*
→ [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/)

**Tombstone** (pierre tombale) — Un document supprimé que Facet garde encore
en mémoire, pour l’historique et la restauration. Une pierre tombale est
invisible dans les listes et la recherche. *Utilisé dans les pages
techniques.*
→ [Rétention : ce qui est gardé](/fr/admin/history/retention/)

## Voir aussi

- [Qu’est-ce que Facet](/fr/discover/why-facet/)
- [Architecture en un coup d’œil](/fr/discover/how-it-works/)
- [Sécurité et gouvernance](/fr/discover/security/)
