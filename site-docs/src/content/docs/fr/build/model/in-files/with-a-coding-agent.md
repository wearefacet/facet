---
type: how-to
title: Bâtir des domaines avec un agent
description: Laissez un agent de code IA écrire les fichiers du domaine pendant que le watcher applique chaque enregistrement et remonte les erreurs.
audience: [developer]
features: [DOM-19, AI-06]
sidebar:
  order: 2
verified_at: eee55a2
---

Vous êtes un développeur qui construit avec un agent de code IA, et le
domaine que vous modélisez a sa place dans la gestion de versions, pas
dans des clics dans l’éditeur. Donnez à l’agent le dossier de fichiers,
laissez le watcher appliquer chaque enregistrement, et laissez le rapport
de vérification dire à l’agent quoi corriger. La boucle tourne sans
navigateur.

## La boucle

<!-- d2
agent: "Coding agent edits files"
watcher: "Watcher applies the bundle"
check: "Check runs, log line written"
report: "Agent reads the check report"
fix: "Agent fixes the files" {class: ok}

agent -> watcher: save
watcher -> check
check -> report
report -> fix: issues
report -> agent: clean {class: ok}
fix -> agent
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/fed7ea85-light.svg" alt="Coding agent edits files" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/fed7ea85-dark.svg" alt="Coding agent edits files" loading="lazy" />
</div>

## Quand l’utiliser

- Vous modélisez un domaine en fichiers, et un agent tape à votre place.
- Vous voulez l’historique du domaine en commits, avec des diffs relisibles
  en revue.
- Vous construisez un domaine et une app ensemble, dans un même dépôt.

## Avant de commencer

- **Un serveur de dev avec le watcher actif** — voir
  [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/).
  Gardez `documents: preserve` pendant qu’un agent travaille ; `discard`
  efface les lignes créées dans l’app à chaque enregistrement.
- **Un dossier par domaine sous gestion de versions**, disposé comme le
  décrit
  [La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/).
- **L’accès à l’endpoint du rapport de vérification**, pour que l’agent
  puisse lire ses propres erreurs.

## Que donner à l’agent

Un agent travaille à partir de texte. Donnez-lui ceci, dans cet ordre :

1. **La doc du site.** `npm run build` dans `site-docs/` produit
   `llms-full.txt` et un jumeau `.md` pour chaque page — un fichier qu’un
   agent peut ingérer.
2. **Le schéma de doctype généré** sous `reference/doctype-schema/` — les
   clés de définition et leurs types.
3. **`doc/ops/build-a-domain.md`** dans le dépôt — la recette API pour la
   boucle brouillon et le chemin direct, avec les codes de statut.
4. **`doc/backend/portable-domains.md`** dans le dépôt — le format de
   bundle, les règles de validation, et chaque erreur que l’import peut
   répondre.

Un corpus qu’un agent ne peut pas atteindre : les fichiers de compétence
internes de l’assistant du Builder. Ils ne sont montés qu’à l’intérieur de
l’assistant intégré à l’app, jamais par une route qu’un agent externe
pourrait appeler. La doc du site couvre le même terrain.

## Un prompt de départ qui fonctionne

````text
You are extending a Facet domain in files. The folder
site-docs/examples/brightwater/equipment.facet-domain holds the running
example; its layout is the Facet bundle format.

Read these first:
- site-docs/src/content/docs/build/model/in-files/domain-files.md (the layout)
- site-docs/src/content/docs/build/model/data/design-doctypes.md (definitions)

Then: add a Supplier doctype to the equipment domain. Fields: name
(string, required), city (string), lead_time_days (integer). Give it a
display_name template and add a reference field `supplier` to
equipment.Item. Keep every file valid YAML; reference targets use the
qualified equipment.Supplier form.

After each save, read the watcher's log line and
GET /Api/dev/check-report?domain=equipment (Authorization header from
`facet-cli apikey`). Fix every issue before you finish. Commit with a message
that says what you modelled.
````

La boucle qui suit est mécanique : l’agent enregistre, le watcher
synchronise, le rapport nomme ce qui est cassé, l’agent corrige. Un
rapport propre est la ligne d’arrivée — le même rapport que le Builder
montre à un auteur humain.

## Relire le diff

Le garde-fou est git, et le diff se lit comme toute revue de code :

- **Un enregistrement, un commit.** Demandez à l’agent de committer après
  chaque étape qui fonctionne, pour qu’une mauvaise modification revienne
  en arrière toute seule.
- **Les lignes de journal sont la campagne de tests.**
  `[dev-sync] synced 'equipment' …` compte ce qui est arrivé ; la ligne de
  vérification compte ce qui est faux. Pas de ligne verte, pas de merge.
- **Lisez le rapport, pas seulement le compteur.**
  `GET /Api/dev/check-report` renvoie chaque anomalie avec son champ et
  son message — la même forme que la boîte de dialogue de publication.
- **Les modifications de données ne se relisent pas ainsi.** Le mode
  `preserve` garde les lignes créées dans l’app, mais un arbre
  `documents/` du bundle modifie les données via les fichiers. Relisez ces
  diffs comme des migrations de données.

## Dépannage

**L’agent modifie des fichiers hors d’un bundle.**

Un fichier hors d’un dossier `{name}.facet-domain/` est invisible pour le
watcher. Pointez le prompt vers le dossier exact, et gardez les fichiers
de travail ailleurs.

**Deux domaines avec le même nom.**

Deux dossiers qui déclarent le même `source_domain` sont en conflit ;
seul le premier dans l’ordre alphabétique se synchronise, et le journal
avertit à chaque cycle. Un dossier par domaine.

**L’agent cherche une erreur de garde de version.**

Il n’y en a pas en mode fichiers. Le watcher importe à neuf à chaque
fois, donc une modification destructive s’applique directement — pas de
montée de `schema_version`, pas de migration. C’est pourquoi la gestion de
versions est le garde-fou, et pourquoi une modification destructive
discutable mérite son propre commit que vous pouvez ramener en arrière.

**L’agent ne peut pas lire le rapport de vérification.**

L’endpoint exige une authentification et un serveur de dev. En production
il répond `404` — pointez l’agent vers l’instance de dev.

## Voir aussi

- [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/) — la synchronisation que les enregistrements de l’agent déclenchent.
- [La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/) — les fichiers que l’agent modifie.
- [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/) — le rapport que l’agent lit.
- [Bâtir des apps avec un agent de code](/fr/build/apps/agents/coding-agents/) — la moitié app de l’histoire.
- Doc interne sur GitHub : [dev-domain-watcher.md](https://github.com/wearefacet/facet/blob/main/doc/backend/dev-domain-watcher.md).
- [Choisir sa façon de construire](/fr/build/model/)
