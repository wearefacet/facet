---
title: Téléverser et servir des fichiers
description: Stockez les octets des fichiers dans des artefacts, joignez-les aux documents et servez-les via des URLs signées.
type: how-to
audience: [developer]
features: [PLT-04]
verified_at: eee55a2
sidebar:
  order: 4
---

Facet stocke les octets des fichiers dans des artefacts. Un champ `file`
d’un document porte l’id d’un artefact, pas les octets. Un champ longtext
peut embarquer un lien `urn:facet:artifact:<id>`. Les lectures des octets
passent par des URLs signées à durée de vie courte.

> **Pour les agents :** À l’écriture, joignez avec
> `POST /Api/<domain>/<doctype>` (ou `PATCH`) en
> `multipart/form-data` — une part `$content` avec le JSON du document plus
> une part par champ `file`. Hors document : `POST /Api/core/artifacts` avec
> une part `file` répond `201 {id, filename, mime_type, size, sha256}`.
> `GET /Api/core/artifacts/:id` renvoie une `url` signée fraîche ; forgez-en
> une autre avec `POST /Api/core/artifacts/:id/grant`. Révoquez avec
> `DELETE /Api/core/artifacts/grants/:gid`. Servez une origine d’app avec
> `GET /Api/core/artifacts/:id/download?app=<APP_ID>` (`Origin` enregistrée).

## Quand l’utiliser

Utilisez cette page quand :

- Vous joignez des fichiers à des documents au fil des enregistrements.
- Vous téléversez un fichier avant de connaître le document qui
  l’accueillera.
- Vous servez des images ou des téléchargements à des personnes sans session
  Facet.

## Avant de commencer

- Un artefact est un ensemble d’octets avec des métadonnées. Il n’appartient
  à aucun domaine.
- Un artefact devient lisible par d’autres quand son id atterrit dans un
  document. L’enregistrement ajoute une ligne de propriétaire. Le
  téléversement seul ne donne aucun droit.
- Un champ `file` porte l’id de l’artefact. Un lien longtext partage le
  fichier avec chaque lecteur du document.
- Le plafond de téléversement est de 50 MiB par requête par défaut
  (`artifact.max_upload_bytes`) ; un corps trop volumineux répond
  `413`.
- Pour joindre à l’écriture, il vous faut les droits `create` ou `update`
  sur le doctype cible. Pour servir depuis l’origine de votre app,
  l’origine doit être enregistrée sur une app active — voir
  [CORS et origines autorisées](/fr/build/apps/connect/cors/).

Les appels réels de cette page ont été exécutés sur une instance de dev à
l’adresse `https://facet.localhost:3443` avec les données Brightwater Rentals
chargées.

## Étapes

### 1. Joignez des fichiers à l’écriture

Chaque appel API présente son propre identifiant. Émettez une clé épinglée
au rôle `manager` de Nadia et gardez-la dans une variable :

```sh
NADIA_KEY=$(pnpx @facetapp/cli connect --role manager >/dev/null && pnpx @facetapp/cli apikey)
```

Un seul appel multipart crée le document et téléverse les parts dans une
même transaction :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -F '$content={"name": "Café des Sports", "city": "Vienne"};type=application/json' \
  -F 'logo=@/path/to/logo.png'
```

La part `$content` porte le JSON du document. Chaque champ `file` voyage
dans une part nommée d’après son chemin de champ : `logo`,
`avatars[0].file`, `items[0].file`. Le serveur téléverse les octets et place
l’id de l’artefact dans le champ. Un échec annule ensemble les
téléversements et le document.

### 2. Téléversez hors document, puis liez

Quand le document n’existe pas encore, téléversez d’abord. Cette session a
téléversé un fichier texte de deux lignes :

```sh
printf 'Brightwater invoice, season 2026\nTotal: 1 240 EUR\n' > sample.txt

curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  -F 'file=@sample.txt;type=text/plain' \
  https://facet.localhost:3443/Api/core/artifacts
```

La réponse est `201` :

```json
{
  "id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "filename": "sample.txt",
  "mime_type": "text/plain",
  "size": 50,
  "sha256": "0387edeb06179ee53dcdab018063aa7253615b0b28e97b748bae04ecb09ffbb7"
}
```

Le compte qui téléverse reste le seul lecteur tant que l’id n’a pas atterri
dans un document. Collez l’id dans un champ `file`, ou embarquez
`urn:facet:artifact:06H1FS5YBW6JQ7R39DQBK6T236` dans un longtext, puis
enregistrez. Chaque lecteur du document peut alors lire le fichier. La purge
balaie un téléversement non lié après la fenêtre de rétention.

### 3. Lisez les métadonnées et forgez une URL fraîche

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236
```

La réponse est la forme du téléversement plus deux membres :

```json
{
  "id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "filename": "sample.txt",
  "mime_type": "text/plain",
  "size": 50,
  "sha256": "0387edeb06179ee53dcdab018063aa7253615b0b28e97b748bae04ecb09ffbb7",
  "url": "https://facet.localhost:3443/A/06H1FS5YF8NMQWGA39QDAFRN8S?exp=1795700796&sig=JwJ1NpGQ_DNumjlYj96z3scupyAGD0j_LJvpkE1pS0k",
  "expires_at": "2026-11-26T13:46:36Z"
}
```

`url` est une URL de service signée ; elle change à chaque lecture — chaque
appel forge une attribution fraîche. `POST /Api/core/artifacts/:id/grant`
forge une autre URL sans les métadonnées :

```json
{
  "grant_id": "06H1FS6HNCZ1C6KWKZXMZSRDAE",
  "artifact_id": "06H1FS5YBW6JQ7R39DQBK6T236",
  "url": "https://facet.localhost:3443/A/06H1FS6HNCZ1C6KWKZXMZSRDAE?exp=1795700801&sig=1c4MSJtJHj33Ute1t-JujvVaAlXskA3u-tpVW0uuL_8",
  "expires_at": "2026-11-26T13:46:41Z"
}
```

Le TTL est calculé par le serveur : environ 1 heure pour les documents et
les images, 6 heures pour l’audio et la vidéo.

### 4. Servez un fichier à un navigateur

La passerelle de téléchargement vérifie l’authentification, le droit de
lecture, puis forge l’attribution et répond `302` vers l’URL signée :

```sh
curl -sk -D - -o /dev/null -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236/download' | grep -i location
# location: https://facet.localhost:3443/A/06H1FS5YJC402HNNVJHGAF529V?exp=…&sig=…
```

Placez l’URL de la passerelle dans un `<a href>` ou un `<img src>` depuis
l’origine de votre app. Quand `?app=<APP_ID>` est présent, la requête doit
porter un en-tête `Origin` qui correspond à une origine autorisée
enregistrée. La passerelle résout l’app depuis l’`Origin`, vérifie qu’il
vaut la valeur de `?app=`, et lit sous le plafond d’attribution de l’app.
Sans en-tête `Origin`, la partie `?app=` est ignorée : l’appel retombe sur
une authentification par cookie ou par bearer. Une requête sans aucun
identifiant tourne sous le rôle anonymous créé par l’initialisation. La
passerelle répond `Cache-Control: no-store`, donc chaque clic forge une
attribution fraîche.

### 5. Publiez une URL permanente, ou révoquez

Une URL permanente n’expire pas. Elle exige une permission nommée — l’action
`publish_artifact` sur le doctype propriétaire. Le droit `read` seul ne
suffit pas. L’appel nomme la ligne propriétaire qui lie
l’attribution :

```sh
curl -sk -X POST \
  https://facet.localhost:3443/Api/core/artifacts/06H1FS5YBW6JQ7R39DQBK6T236/publish \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"owner_id": "<owner document id>"}'
```

Révoquez n’importe quelle attribution avec
`DELETE /Api/core/artifacts/grants/:gid` :

```sh
curl -sk -X DELETE -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/core/artifacts/grants/06H1FS6HNCZ1C6KWKZXMZSRDAE
# 204
```

Après la révocation, l’URL de cette attribution cesse de servir. Le point de
contrôle accepte `publish_artifact` sur le document propriétaire, l’action
opérateur `revoke *.*`, ou le contournement système.

## Exemple

Le SDK TypeScript reflète ces routes — voir
[Le SDK TypeScript](/fr/build/apps/data/sdk/) :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');
const doc = companies.doc('06H1FM1B3MXBPS0JYVM3BDD154');
// file est le fichier à téléverser ; ownerId nomme la ligne propriétaire à lier.

// Joindre : un seul appel multipart. Les téléversements et la mutation
// partagent une transaction côté serveur.
await companies.create({ name: 'Café des Sports' }, { files: { logo: file } });
await doc.update({ name: 'Café des Sports' }, { files: { 'items[0].file': file } });

// Téléversement hors document, puis liez l’id ou l’URN.
const { id, filename } = await facet.artifacts.upload(file);
await facet.artifacts.uploadAsUrn(file); // urn:facet:artifact:<id> pour les longtexts

// Lire des URLs pour quelqu’un sans session.
const grant = await facet.artifacts.grant(id); // éphémère ; le serveur déduit le TTL
const meta = await facet.artifacts.show(id);
await facet.artifacts.revoke(grant.grant_id);

// Une URL publique permanente exige l’action publish_artifact sur un
// document propriétaire ; la ligne de provenance lie l’attribution.
await facet.artifacts.publish(id, { ownerId });

// <a href> / <img src> : la passerelle forge une attribution fraîche par requête.
facet.artifacts.downloadUrl(id);
facet.artifacts.downloadUrl(id, { appId }); // lectures depuis l’origine de l’app
const bytes = await facet.artifacts.download(id); // suit le 302, renvoie les octets
```

## Notes de comportement

- **Le MIME vient des octets.** Le serveur reconnaît les magic bytes et
  ignore le `Content-Type` du client. Un type inconnu devient
  `application/octet-stream`.
- **La déduplication réutilise des octets que vous pouvez lire.** Des octets
  identiques sous une provenance lisible sont réutilisés ; l’écriture
  dans le stockage est sautée.
- **La route de service durcit les réponses.** Elle envoie `nosniff`, une
  politique de sécurité du contenu (CSP), et un `Content-Disposition` qui
  suit le type MIME.
- **Retirer un lien ne révoque pas l’accès.** La ligne propriétaire que le
  document a ajoutée reste.
- **Les champs `file` s’exportent comme ids seulement.** Les octets ne
  voyagent pas dans un export en masse — voir
  [Import/export en masse](/fr/build/apps/data/bulk-import-export/).

## Dépannage

**Un téléchargement répond `403`.**

Aucune provenance lisible : l’id ne figure dans aucun document que votre
identifiant peut lire. Liez-le dans un document que vous pouvez lire, ou
lisez-le comme téléverseur.

**Un téléversement répond `413`.**

Le corps dépasse le plafond, 50 MiB par défaut. Découpez le fichier.

**Un téléversement répond `415`.**

La route n’accepte que `multipart/form-data`. Envoyez le fichier en part.

**Une URL signée a cessé de marcher.**

Le TTL a expiré. Forgez-en une fraîche ; le serveur déduit le TTL du type
MIME.

**L’image s’affiche pour un collègue mais répond `403` dans votre app.**

Le chemin depuis l’origine d’app exige à la fois `?app=<APP_ID>` et un
en-tête `Origin` qui correspond à une origine autorisée enregistrée.
Vérifiez les deux.

**La révocation d’une attribution n’a pas retiré l’artefact.**

Une révocation supprime une seule attribution. Un nouvel appel `show` ou
`download` en forge une nouvelle. Déliez l’artefact de chaque document pour
retirer l’accès en lecture définitivement.

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — les routes de documents sur
  lesquelles repose l’entrée multipart.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — les utilitaires
  `facet.artifacts`.
- [CORS et origines autorisées](/fr/build/apps/connect/cors/) — enregistrer l’origine
  que la passerelle vérifie.
- [Outils pour agents](/fr/build/apps/agents/agent-tools/) — `get_artifact` et
  `request_artifact_upload` pour les agents.
- Internes sur GitHub :
  [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md).
