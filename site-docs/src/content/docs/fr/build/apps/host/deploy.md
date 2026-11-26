---
title: Déployer votre frontend
description: Déployez un build statique, listez les releases, revenez en arrière et définissez un domaine personnalisé.
audience: [developer]
features: [APP-06, APP-09]
sidebar:
  order: 8
verified_at: a77c6171
---

Facet sert votre build statique sur l’hôte propre à l’app. Le build est une
donnée, pas une configuration : un document `app.App` porte `host` et
`active_deployment`. Un déploiement passe en ligne sans redémarrage ni
changement de configuration. Une app sans valeur `host` n’est jamais servie.

> **Pour les agents :** déployez avec `pnpx @facetapp/cli deploy --note "build"`,
> ou envoyez un POST multipart sur `/Api/app/<app id>/deploy` : une partie JSON
> `$content`
> (`{"spa": true, "activate": true, "note": "build", "files": [{"path": "index.html"}]}`)
> plus une partie `files[<i>].file` par fichier. Auth :
> `Authorization: Bearer <token>` ; l’appelant a besoin de `deploy` sur
> `app.App` dans attribution ∩ rôle. Liste :
> `GET /Api/app/Deployment?filters[app_id__eq]=app.App.<id>&sort=-revision`.
> Retour arrière : `PATCH /Api/app/App/<id>` avec
> `{"active_deployment": "app.Deployment.<id>"}`.

## Quand l’utiliser

Utilisez cette page quand :

- Vous mettez un nouveau build en ligne sur l’hôte de l’app.
- Vous listez les releases et ramenez une révision défectueuse en arrière.
- Vous servez l’app sur un domaine personnalisé.

## Avant de commencer

- Un document d’app au statut `active`. Une app en brouillon ou désactivée
  refuse les déploiements.
- L’action `deploy` sur `app.App`. Le rôle `admin` créé par l’initialisation
  la porte ; le rôle `editor` pré-créé non. Sur l’API, l’attribution et le
  rôle doivent la porter tous les deux.
- Pour un domaine personnalisé : le contrôle des enregistrements DNS
  (Domain Name System).

## Le modèle

Chaque déploiement crée un document `app.Deployment`. La route calcule la
`revision` : la plus haute révision de l’app plus un. L’étape d’activation
pose `active_deployment` sur l’app ; le dispatcher sert les fichiers de ce
déploiement.

Le drapeau `spa` vaut `true` par défaut. Un chargement de page qui ne
correspond à aucun fichier retombe sur `index.html`. Un asset manquant répond
`404`.

## Étapes

### 1. Déployer avec la CLI

```sh
pnpx @facetapp/cli deploy --note "fix login bug"
```

La commande parcourt le dossier de build, téléverse une requête multipart et
active la nouvelle révision ; elle affiche la révision attribuée et l’URL de
l’app.

Une requête vaut un déploiement atomique : la création et l’activation
s’exécutent dans une seule transaction.

### 2. Ou appelez directement la route de déploiement

Pour une intégration continue (CI) qui ne peut pas lancer la CLI, appelez
vous-même `POST /Api/app/:id/deploy`. Le `:id` est l’id qualifié de l’app,
`app.App.<id>`, tel que la liste des apps le renvoie. Le corps est un
formulaire multipart :

| Partie | Contenu |
| --- | --- |
| `$content` | Le JSON de déploiement : `spa`, `activate`, `note` et `files`, avec une entrée `{path}` par fichier. Le JSON ne porte aucune valeur `file` ; le serveur injecte les ids d’artifact. |
| `files[0].file`, `files[1].file`, etc. | Une partie par fichier, dans le même ordre que les entrées `files`. |

La route valide chaque `path` selon une règle de chemins sûrs : pas de `/`
initial, pas de `..`, pas de segment vide, UTF-8 valide, et 1024 caractères
au plus. Un fichier en échec annule tout le déploiement.

La route répond `{id, revision, activated, files}` — pas une enveloppe de
document ; `files` compte les fichiers acceptés.

L’appelant a besoin de `deploy` sur `app.App` dans attribution ∩ rôle. Un
token d’app OAuth ou une clé d’API propre à l’app fonctionne avec un simple
en-tête `Authorization: Bearer` ; une session d’opérateur exige en plus
l’en-tête `X-Requested-With` pour le contrôle CSRF (cross-site request
forgery). [L’exemple](#exemple) montre l’appel complet.

### 3. Lister les releases

Avec la CLI :

```sh
pnpx @facetapp/cli releases
```

La liste va de la révision la plus récente à la plus ancienne. La release
active porte un `*`.

Sur l’API :

```http
GET https://facet.example.tld/Api/app/Deployment?filters[app_id__eq]=app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND&sort=-revision
```

La valeur du filtre porte la forme qualifiée, `app.App.<id>` : les champs
référence stockent des tokens qualifiés.

### 4. Revenir en arrière

Revenir en arrière pointe `active_deployment` vers un déploiement plus
ancien. Avec la CLI :

```sh
pnpx @facetapp/cli rollback 2
```

Une révision inconnue échoue avec la liste de celles qui existent.

La forme API est une mise à jour de document ordinaire ; la valeur de
référence est un token qualifié, `app.Deployment.<id>` :

```sh
curl -X PATCH "https://facet.example.tld/Api/app/App/app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"active_deployment": "app.Deployment.01JF3V8QZK4M6TB2X9CWD5PNHR"}'
```

## Domaines personnalisés

Posez `host` sur le document de l’app. La valeur est un nom d’hôte nu en
minuscules : pas de schéma, pas de port, pas de chemin, pas de caractère
joker, et 253 caractères au plus. La valeur est unique d’une app à l’autre,
et Facet refuse un hôte auquel Facet lui-même répond. Pointez les
enregistrements DNS de ce nom d’hôte vers Facet.

Le serveur émet les certificates TLS (Transport Layer Security) à la demande.
Avant d’émettre, le serveur edge appelle le ask endpoint,
`GET /Edge/HostAsk?domain=<name>`. Un nom non approuvé fait échouer le
handshake TLS et ne produit jamais de requête HTTP. Un nom local obtient un
certificate auprès de l’autorité de certificates interne ; un nom public en
obtient un via ACME (Automatic Certificate Management Environment).

Un hôte nouveau ou déplacé s’applique dès la requête suivante : le cache des
hôtes s’invalide à chaque mutation de `app.App` et se reconstruit depuis la
base de données. Aucun redémarrage n’est nécessaire.

Une app porte une seule valeur `host`. Le dispatcher fait correspondre le nom
d’hôte de la requête exactement, jamais comme suffixe.

## La distribution des fichiers

| Réponse | En-tête de cache | Effet |
| --- | --- | --- |
| Shell de l’app : `index.html` et chaque repli de navigation | `public, no-cache` | Le navigateur revalide avant réutilisation. Un déploiement est visible à la navigation suivante. |
| Chaque autre asset | `public, max-age=300` | Le navigateur réutilise l’asset pendant cinq minutes. |

Chaque réponse porte `X-Content-Type-Options: nosniff`. Le type de contenu se
décide au téléversement : l’extension du nom de fichier d’abord, les magic
bytes en repli.

Un build publié est public par conception : quiconque résout l’hôte obtient
les octets. Considérez le build comme du code source lisible. Le HTML, le
JavaScript et le CSS livrés peuvent laisser deviner le schéma du backend,
jamais les données. L’API reste derrière le contrôle d’accès basé sur les
rôles (RBAC).

Les cookies de Facet et ceux des apps ne se mélangent jamais. Les cookies de
session de Facet sont limités à leur hôte, et le garde-fou des hôtes réservés
tient une app à l’écart de l’origine de Facet.

La couche de distribution n’ajoute jamais de mur de connexion. Hébergez une
app privée derrière votre propre filtre réseau : un réseau privé virtuel
(VPN) ou un proxy qui vérifie l’accès.

## Exemple

Cet appel déploie un build depuis une CI. Les parties `files` suivent l’ordre
des entrées `files` de `$content` ; les noms de fichiers des parties portent
les chemins relatifs au build :

```sh
curl -X POST "https://facet.example.tld/Api/app/app.App.01JEX4TA6G9K2MQ7V3BZ8PWRND/deploy" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F '$content={"spa": true, "activate": true, "note": "ci build 42", "files": [{"path": "index.html"}, {"path": "assets/app.js"}]};type=application/json' \
  -F "files[0].file=@dist/index.html;filename=index.html" \
  -F "files[1].file=@dist/assets/app.js;filename=assets/app.js"
```

## Dépannage

**L’hôte de l’app répond un `404` nu.**

Le dispatcher n’a fait correspondre aucune app. La valeur `host` doit égaler
exactement le nom d’hôte de la requête ; une app sans valeur `host` n’est
jamais servie.

**Le déploiement répond `422`.**

L’app est en brouillon ou désactivée, ou son enregistrement est marqué
`no_asset` — un enregistrement headless n’est pas une cible de déploiement.
Un `path` qui enfreint la règle de chemins sûrs donne la même réponse.
Activez l’app ou corrigez les chemins, puis déployez de nouveau.

**Le handshake TLS échoue sur le domaine personnalisé.**

Le ask endpoint n’approuve que les hôtes que Facet connaît. Vérifiez que
`host` est posé sur le document de l’app et nomme exactement le nom d’hôte
demandé.

**Un asset répond `404` après un déploiement.**

Le chemin ne figure pas dans la table de fichiers du déploiement. Le repli
`spa` couvre les chargements de page seulement. Vérifiez que le fichier
existe dans le dossier de build téléversé.

**Le déploiement répond `403`.**

L’attribution et le rôle de l’appelant n’ont pas `deploy` sur `app.App`. Le
rôle `editor` pré-créé ne porte pas l’action. Employez un identifiant dont le
rôle la porte.

**Le déploiement répond `401` avec une clé propre à l’app.**

L’app qui possède la clé est en brouillon ou désactivée. Les clés propres à

une app répondent le `401` uniforme dans ce cas. Activez cette app ou
employez un autre identifiant.

## Voir aussi

- [Démarrage rapide avec la CLI dev](/fr/build/apps/quickstart/) — les
  commandes à la base de cette page.
- [Enregistrer une app](/fr/build/apps/connect/register/) — le statut de l’app et le
  tableau de bord.
- [CORS et origines autorisées](/fr/build/apps/connect/cors/) — comment l’API
  accepte les appels de navigateur depuis l’hôte de l’app.
- [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/) — le modèle
  attribution ∩ rôle derrière la barrière de déploiement.
- Internes sur GitHub :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
