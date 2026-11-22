---
title: Téléverser et servir des fichiers
description: Téléversez des fichiers dans des documents et servez-les via des attributions signées.
audience: [developer]
features: [PLT-04]
sidebar:
  order: 13
verified_at: a77c6171
---

Facet stocke les octets des fichiers dans un stockage objet. Un champ `file`
d’un document porte l’id d’un artefact, pas les octets. Un champ longtext
peut embarquer un lien `urn:facet:artifact:<id>`. Les lectures des octets
passent par des URLs signées à durée de vie courte.

> **Pour les agents :** À l’écriture, joignez avec
> `POST /Api/<domain>/<doctype>` (ou `PATCH`) en `multipart/form-data` — une
> part `$content` avec le JSON du document plus une part par champ `file`.
> Hors document : `POST /Api/core/artifacts` avec une part `file`
> répond `201 {id, filename, mime_type, size, sha256}`.
> `GET /Api/core/artifacts/:id` renvoie une `url` signée fraîche (TTL 1 h ;
> médias 6 h) ; forgez-en une autre avec
> `POST /Api/core/artifacts/:id/grant`. Servez une origine d’app avec
> `GET /Api/core/artifacts/:id/download?app=<APP_ID>` (`Origin` enregistrée).

## Quand l’utiliser

Utilisez cette page quand :

- Vous joignez des fichiers aux documents quand les utilisateurs
  enregistrent.
- Vous téléversez un fichier avant de connaître le document qui le portera.
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
  l’origine doit être enregistrée sur une app active — voir [CORS et
  origines autorisées](/fr/apps/cors-origins/).

## Étapes

### 1. Joignez des fichiers à l’écriture

Un seul appel multipart crée le document et téléverse les parts dans une
transaction :

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F '$content={"name": "Acme"};type=application/json' \
  -F 'logo=@/path/to/logo.png'
```

La part `$content` porte le JSON du document. Chaque champ `file` voyage
dans une part nommée d’après son chemin de champ : `logo`,
`avatars[0].file`, `items[0].file`. Le serveur téléverse les octets et place
l’id de l’artefact dans le champ. Un échec annule ensemble les
téléversements et le document.

### 2. Téléversez hors document, puis liez

Quand le document n’existe pas encore, téléversez d’abord :

```sh
curl -s -X POST "https://facet.company.tld/Api/core/artifacts" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -F 'file=@/path/to/report.pdf'
```

La réponse est `201` :

```json
{
  "id": "01JARQ5G7X9K2M3N4P5Q6R7S8T",
  "filename": "report.pdf",
  "mime_type": "application/pdf",
  "size": 48213,
  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
}
```

Le compte qui téléverse reste le seul lecteur tant que l’id n’a pas atterri
dans un document. Collez l’id dans un champ `file`, ou embarquez
`urn:facet:artifact:01JARQ5G7X9K2M3N4P5Q6R7S8T` dans un longtext, puis
enregistrez. Chaque lecteur du document peut alors lire le fichier. La purge
balaie un téléversement non lié après la fenêtre de rétention.

### 3. Lisez les métadonnées et forgez une URL fraîche

```sh
curl -s "https://facet.company.tld/Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T" \
  -H "Authorization: Bearer $FACET_TOKEN"
```

La réponse est la forme du téléversement plus deux membres : `url`,
l’URL signée qui sert le fichier, et `expires_at`. L’URL change à chaque
lecture. `POST /Api/core/artifacts/:id/grant` forge une autre URL sans les
métadonnées. Le TTL est calculé par le serveur : 1 heure pour les
documents et les images, 6 heures pour l’audio et la vidéo.

### 4. Servez un fichier à un navigateur

La passerelle de téléchargement fait la vérification d’authentification, la
vérification de lecture et le forgeage, puis répond `302` vers l’URL
signée :

```http
GET /Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T/download?app=01JHQ9M4T8C3XK2PB5WY6RD7QF
```

Placez l’URL dans un `<a href>` ou un `<img src>` depuis l’origine de votre
app. Quand `?app=` est présent, la requête doit porter un en-tête `Origin`
qui correspond à une origine autorisée enregistrée. La passerelle résout
l’app depuis l’`Origin`, vérifie qu’il vaut la valeur de `?app=`, et lit
sous le plafond d’attribution de l’app. Sans en-tête `Origin`, la partie
`?app=` est ignorée : l’appel retombe sur une authentification par
cookie ou par bearer. Une requête sans aucun identifiant tourne sous le rôle
`anonymous` créé par l’initialisation. La passerelle répond
`Cache-Control: no-store`, donc chaque clic forge une attribution fraîche.

### 5. Publiez une URL permanente, ou révoquez

Une URL permanente n’expire pas. Elle exige une permission nommée — l’action
`publish_artifact` sur le doctype propriétaire. Le droit `read` seul ne
suffit pas. L’appel nomme la ligne propriétaire qui lie
l’attribution :

```sh
curl -s -X POST "https://facet.company.tld/Api/core/artifacts/01JARQ5G7X9K2M3N4P5Q6R7S8T/publish" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"owner_id": "01JGK2M4N6P8R0T2V4X6Z8B2D4"}'
```

Révoquez n’importe quelle attribution avec
`DELETE /Api/core/artifacts/grants/:gid`. Le point de contrôle accepte
`publish_artifact` sur le document propriétaire, l’action opérateur
`revoke *.*`, ou le contournement système.

## Exemple

Le SDK TypeScript reflète ces routes — voir [Le SDK
TypeScript](/fr/apps/typescript-sdk/) :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
  baseUrl: 'https://facet.company.tld',
  auth: staticKey(process.env.FACET_API_KEY!),
});
const companies = facet.domain('crm').doctype('Company');
const doc = companies.doc('crm.Company.abc');
// file est le fichier à téléverser ; ownerId nomme la ligne propriétaire à lier.

// Joindre : un seul appel multipart. Les téléversements et la mutation
// partagent une transaction côté serveur.
await companies.create({ name: 'Acme' }, { files: { logo: file } });
await doc.update({ name: 'Acme' }, { files: { 'items[0].file': file } });

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
  Content Security Policy (CSP), et un `Content-Disposition` qui suit le
  type MIME.
- **Retirer un lien ne révoque pas l’accès.** La ligne propriétaire que le
  document a ajoutée reste.
- **Les champs `file` s’exportent comme ids seulement.** Les octets ne
  voyagent pas dans un export en masse — voir
  [Import/export en masse via l’API](/fr/apps/bulk-import-export/).

## Dépannage

**Un téléchargement répond `403`.**

Aucune provenance lisible : l’id n’est dans aucun document que vos
identifiants peuvent lire. Liez-le dans un document que vous pouvez lire, ou
lisez-le comme le compte qui l’a téléversé.

**Un téléversement répond `413`.**

Le corps dépasse le plafond, 50 MiB par défaut. Découpez le fichier.

**Un téléversement répond `415`.**

La route n’accepte que `multipart/form-data`. Envoyez le fichier comme une
part.

**Une URL signée a cessé de marcher.**

Le TTL a expiré. Forgez-en une nouvelle ; le serveur déduit le TTL du
type MIME.

**L’image s’affiche chez un collègue mais répond `403` dans votre app.**

Le chemin par origine d’app exige à la fois `?app=<APP_ID>` et un en-tête
`Origin` qui correspond à une origine autorisée enregistrée. Vérifiez les
deux.

## Voir aussi

- [Utiliser l’API REST](/fr/apps/rest-api/) — les routes de documents
  qu’emprunte la réception multipart.
- [Le SDK TypeScript](/fr/apps/typescript-sdk/) — les utilitaires
  `facet.artifacts`.
- [CORS et origines autorisées](/fr/apps/cors-origins/) — l’enregistrement
  de l’origine que la passerelle vérifie.
- [Outils pour agents](/fr/apps/agent-tools/) — `get_artifact` et
  `request_artifact_upload` pour les agents.
- Internes sur GitHub :
  [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md).
