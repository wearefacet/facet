---
type: how-to
title: Lier les tokens à votre app (DPoP)
description: Liez les tokens d’une app à une clé avec des preuves DPoP, à l’échange de token et à chaque appel d’API.
audience: [developer]
features: [APP-03]
sidebar:
  order: 2
verified_at: eee55a2
---

DPoP prouve que le token est utilisé par l’app à laquelle il a été émis,
donc un token volé est inutilisable seul. DPoP (Demonstrating
Proof-of-Possession, RFC 9449) lie le token d’une app à une seule paire
de clés. Les seuls octets d’un token volé ne peuvent pas appeler l’API :
chaque appel porte une preuve fraîche et signée. La liaison est
facultative à la connexion — un échange sans en-tête `DPoP` donne un
bearer token ordinaire. À l’API, un token lié refuse tout par défaut :
chaque présentation incorrecte répond `401`.

> **Pour les agents :** créez une paire de clés ECDSA P-256 avant la
> redirection ; gardez la JWK privée pendant toute la session. Forgez un
> JWT de preuve — en-tête `typ: "dpop+jwt"`, `alg: "ES256"`, `jwk` avec
> les seuls membres publics ; payload `jti` (neuf), `htm`, `htu`, `iat`,
> sans `ath` — et envoyez-le dans l’en-tête `DPoP` sur
> `POST /OAuth/token`. La réponse porte alors `token_type: "DPoP"` et le
> token embarque `cnf.jkt`. À chaque appel d’API :
> `Authorization: DPoP <access_token>` plus une preuve fraîche avec
> `ath = base64url(SHA-256(access_token))`. Signez `htu` comme l’origine
> configurée plus le chemin — jamais la barre d’adresse, jamais avec une
> partie query. Le refresh exige une preuve fraîche avec la même clé.

## Quand l’utiliser

- **Le vol de token vous concerne.** Un access token volé est inutilisable
  sans la clé privée.
- **Votre app sait garder une clé.** Elle génère une paire de clés et
  garde la clé privée pendant toute la session.
- **Ni cookies ni WebSockets.** Un token lié ne voyage ni dans un cookie
  ni dans une négociation WebSocket — voir
  [Mises à jour en direct](/fr/build/apps/data/realtime/).

  Pour une app bearer non liée, sautez cette page ; l’échange n’envoie
  aucun en-tête `DPoP`.

## Avant de commencer

- Exécutez d’abord le flux de connexion — voir
  [Connecter les utilisateurs](/fr/build/apps/connect/user-login/).
- Générez la paire de clés avant la redirection, et conservez le matériel
  privé pendant tout l’aller-retour. Le client de référence stocke les
  deux JWK dans `sessionStorage`.
- Une clé perdue donne un `401` sans indice. Aucun recours n’existe :
  générez une nouvelle clé et recommencez une connexion.

## Étapes

### 1. Générez une clé et gardez-la pour toute la connexion

Utilisez une paire de clés ECDSA P-256 par connexion. Gardez la JWK
privée dans le navigateur ; Facet ne la voit jamais. Chaque en-tête de
preuve ne porte que les membres publics `kty`, `crv`, `x`, `y` — un
membre privé comme `d` invalide la preuve.

### 2. Forgez une preuve d’émission à l’échange de token

La preuve est un JWT ES256. L’en-tête JOSE porte `typ: "dpop+jwt"`,
`alg: "ES256"` et le `jwk` public. Le payload porte `jti` (une valeur
aléatoire neuve), `htm: "POST"`, `htu` (l’URL du token) et `iat`
(secondes unix). Pas de `ath` — l’access token n’existe pas encore, et
une preuve qui en porte un est rejetée. Envoyez la preuve dans l’en-tête
`DPoP` sur `POST /OAuth/token`. Une preuve vérifiée renvoie
`token_type: "DPoP"`, et l’access token embarque `cnf.jkt` — l’empreinte
de la clé de preuve.

Cet échange a tourné contre l’instance Brightwater. La preuve, forgée
pour le `htu` `https://facet.localhost:3443/OAuth/token` :

```sh
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0IiwiandrIjp7Imt0eSI6IkVDIiwiY3J2IjoiUC0yNTYiLCJ4Ijoid2RlMlAzMTI3UFZnSng2VlltSVY2Qm9ETVZPUEZsTWNIRGEweE91RnFoayIsInkiOiJhYkVnMTF3ZFhsSTRzRUFHcDR4TWVydXZ2Y250eVdTV1ExOTZEZEtJWFVJIn19.eyJqdGkiOiJjNTRkOTIxYy1jMjllLTRkMGUtYTFmMS0wOTM3Y2E5Njg4MTEiLCJodG0iOiJQT1NUIiwiaHR1IjoiaHR0cHM6Ly9mYWNldC5sb2NhbGhvc3Q6MzQ0My9PQXV0aC90b2tlbiIsImlhdCI6MTc5NTcwMDQ0NX0.nOo0MLl6DsdTj1q8JG7UgLAqWVMpsAueHLn-XEVhSgl-kQhgFWwior5Dmb6x_66tIBTIm9elxOMvVnnfaN3Swg
```

```sh
curl -sk -X POST https://facet.localhost:3443/OAuth/token \
  -H "DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0IiwiandrIjp7Imt0eSI6IkVDIiwiY3J2IjoiUC0yNTYiLCJ4Ijoid2RlMlAzMTI3UFZnSng2VlltSVY2Qm9ETVZPUEZsTWNIRGEweE91RnFoayIsInkiOiJhYkVnMTF3ZFhsSTRzRUFHcDR4TWVydXZ2Y250eVdTV1ExOTZEZEtJWFVJIn19.eyJqdGkiOiJjNTRkOTIxYy1jMjllLTRkMGUtYTFmMS0wOTM3Y2E5Njg4MTEiLCJodG0iOiJQT1NUIiwiaHR1IjoiaHR0cHM6Ly9mYWNldC5sb2NhbGhvc3Q6MzQ0My9PQXV0aC90b2tlbiIsImlhdCI6MTc5NTcwMDQ0NX0.nOo0MLl6DsdTj1q8JG7UgLAqWVMpsAueHLn-XEVhSgl-kQhgFWwior5Dmb6x_66tIBTIm9elxOMvVnnfaN3Swg" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode 'code=3oLGa5snVVSHSYRm4CYsgR82-uzy3cZ_c4U3YzeW8kk' \
  --data-urlencode 'client_id=06H1FQF7NG357EQ0P348Z2BEV5' \
  --data-urlencode 'redirect_uri=http://localhost:5173/auth/callback' \
  --data-urlencode 'code_verifier=YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F'
```

La réponse marque le token comme lié :

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjI0YzZmZTUxZmQ5Nzk1ZGJhYzg5NGNiN2VkYzNjYzA1ZTZhOTEzMDM3MDY1MDMxZjgxYWVhZmJkMmM5ZmJhZWUiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc1SkowMDhNSlNHTkpaNEUxUVY5SjIiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDA0NDUsImV4cCI6MTc5NTcwMTM0NSwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00iLCJjbmYiOnsiamt0IjoiTmxiU0RfUkM5YUJCRU1EVXFVV3hvS1B0XzNLNWhVa0wzOTkySHZmNEtlOCJ9fQ.-aPyzWALHqJnto9aBAkAdvjAXlwoUVrUZ1ZkoMjNnhhSoNxx7pedC_zJW9_UCy8CTGQ2i-G4KcLCy6OGGpTZrA",
  "token_type": "DPoP",
  "expires_in": 900,
  "refresh_token": "24c6fe51fd9795dbac894cb7edc3cc05e6a913037065031f81aeafbd2c9fbaee.f975a56ce92e5729c3891d120db06bb8fc4e5fccebdedfcc0aee978f0fc8ab6d"
}
```

Décodé, le payload de l’access token porte maintenant la liaison :

```json
{
  "sub": "06H1FM098WB2B7X5BA49466K4N",
  "sid": "24c6fe51fd9795dbac894cb7edc3cc05e6a913037065031f81aeafbd2c9fbaee",
  "role": "iam.Roles.admin",
  "typ": "app",
  "app": "06H1FQF7NGDJJKSNHXPYT6627M",
  "cnf": { "jkt": "NlbSD_RC9aBBEMDUqUWxoKPt_3K5hUkL3992Hvf4Ke8" }
}
```

:::tip
L’endpoint de token vérifie la preuve avant de consommer le code. Une
preuve en échec ne consomme pas le code — corrigez la preuve et échangez
le même code une seconde fois.
:::

### 3. Rafraîchissez une session liée avec la même clé

Chaque refresh d’une session liée exige une preuve fraîche avec la même
clé : `jti`, `htm: "POST"`, l’URL du token, `iat`, et pas de `ath`. Une
preuve absente, une clé différente ou une preuve rejouée révoque la
session et répond `invalid_grant`.

### 4. Prouvez la possession à chaque appel d’API

Envoyez le token lié avec le schéma `DPoP`, plus une preuve fraîche à
chaque requête. Le serveur compare `htu` et ignore les parties query et
fragment, donc la chaîne de requête n’entre jamais dans la preuve :

```http
GET /Api/rentals/Booking?items=1
→ proof htu: https://facet.localhost:3443/Api/rentals/Booking
```

Le contrat de la preuve, claim par claim :

| Claim | Endpoint de token | Refresh | Appel d’API | Violation |
| --- | --- | --- | --- | --- |
| `jti` | requis, non vide | requis | requis, neuf à chaque requête | attribution : `400` ; API : `401` |
| `htm` | `POST` | `POST` | la méthode de la requête | divergence : erreur |
| `htu` | l’URL du token | l’URL du token | chemin de la requête, sans query ni fragment | divergence : erreur, nomme les deux URLs |
| `iat` | dans la fenêtre de décalage | dans la fenêtre de décalage | dans la fenêtre de décalage | hors fenêtre : erreur |
| `ath` | doit être absent | doit être absent | requis : `base64url(SHA-256(access_token))` | faux ou inattendu : erreur |

Les valeurs de `jti` servent une seule fois ; le serveur met en cache
les valeurs acceptées, donc une preuve rejouée répond `401`. La fenêtre
`iat` accepte 10 secondes dans le futur et 30 secondes dans le passé
(valeurs par défaut). Aux attributions de token et de refresh, un échec
de preuve répond `400` — `invalid_dpop_proof` pour un défaut de
structure ou de signature, `invalid_claim` pour un défaut de payload,
`invalid_grant` pour un rejeu. À l’API, chaque échec donne le même
`401`.

Un appel lié, de bout en bout. Calculez d’abord `ath`, puis forgez la
preuve, puis envoyez les deux en-têtes :

```sh
# ath = base64url(SHA-256(access_token))
printf '%s' "$TOKEN" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
# jYnrjvsf4YY4csgr1DneikyppbGtRL5zPZeoad_BE-s

curl -sk 'https://facet.localhost:3443/Api/rentals/Booking?items=1' \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(node dpop.mjs proof GET https://facet.localhost:3443/Api/rentals/Booking jYnrjvsf4YY4csgr1DneikyppbGtRL5zPZeoad_BE-s)"
```

La fabrication de la preuve elle-même est le module TS de la section
Exemple ; l’appel répond `200` avec la première réservation. Rejouez les
mêmes en-têtes et le `jti` de la preuve est dépensé :

```
{"error": "Authentication required"}
```

La voie de rétrogradation est fermée aussi — le même token lié sous le
schéma `Bearer` simple répond le même
`401 {"error": "Authentication required"}`, même quand le token est par
ailleurs valide.

### 5. Signez l’origine configurée, pas la barre d’adresse

Le serveur reconstruit `htu` à partir de la seule origine publique
configurée. Il ne lit jamais les en-têtes `X-Forwarded-*`. Une preuve
dont le `htu` diffère par le schéma, l’hôte ou le port répond `400` à
l’endpoint de token et `401` à l’API, avec un message qui nomme les deux
URLs : `DPoP htu mismatch: expected https://facet.localhost:3443/OAuth/token, got http://facet.localhost:3443:8080/OAuth/token`.

:::caution
Un proxy qui termine TLS doit transmettre l’origine publique, ou
l’opérateur doit régler `host` (ou `FACET_HOST` dans la pile de release)
sur l’origine que le navigateur utilise. Un proxy qui transmet des
origines internes casse chaque client DPoP.
:::

### 6. Sachez ce qui refuse par défaut

Trois présentations échouent par conception, et chaque autre échec DPoP
répond le même corps :

| Présentation | Réponse |
| --- | --- |
| Schéma `Bearer` avec un token lié | `401` — la voie de rétrogradation est fermée |
| Schéma `DPoP` avec un token non lié | `401` avec `WWW-Authenticate: Bearer` — le seul échec qui nomme la correction |
| Un token lié dans le cookie `auth_token` ou dans un sous-protocole WebSocket | `401` — ces transports ne peuvent pas porter une preuve |
| Tout autre échec DPoP — preuve absente, clé fausse, `ath`/`htm`/`htu` faux, décalage expiré, `jti` rejoué | `401 {"error": "Authentication required"}` — aucun détail sur la vérification en échec |

## Exemple

Ce module garde la clé, forge les preuves, échange le code et effectue
un appel d’API lié. Générez et enregistrez la clé avant le
`location.assign(...)` de votre connexion :

```ts
// facet-dpop.ts — clé DPoP, fabrication de preuves et appels d’API liés,
// d’après le client de référence e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.localhost:3443';
const TOKEN_URL = `${API_ORIGIN}/OAuth/token`;
const DPOP_STORAGE = 'facet.dpop';

interface DpopKey {
  pub: { kty: string; crv: string; x: string; y: string };
  jkt: string;
  privateJwk: JsonWebKey;
}

function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256B64url(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return b64url(new Uint8Array(digest));
}

export async function generateDpopKey(): Promise<DpopKey> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
    'verify'
  ]);
  const jwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
  const pub = { kty: jwk.kty as string, crv: jwk.crv as string, x: jwk.x as string, y: jwk.y as string };
  // Empreinte RFC 7638 : JSON canonique, membres triés, SHA-256, base64url.
  const jkt = await sha256B64url(JSON.stringify({ crv: pub.crv, kty: pub.kty, x: pub.x, y: pub.y }));
  return { pub, jkt, privateJwk: await crypto.subtle.exportKey('jwk', pair.privateKey) };
}

export function saveDpopKey(key: DpopKey): void {
  sessionStorage.setItem(DPOP_STORAGE, JSON.stringify(key));
}

function loadDpopKey(): DpopKey | null {
  const raw = sessionStorage.getItem(DPOP_STORAGE);
  if (raw === null) return null;
  return JSON.parse(raw) as DpopKey;
}

export async function signDpopProof(key: DpopKey, htm: string, htu: string, ath?: string): Promise<string> {
  const header = { alg: 'ES256', typ: 'dpop+jwt', jwk: key.pub };
  const payload: Record<string, unknown> = {
    jti: crypto.randomUUID(),
    htm,
    htu,
    iat: Math.floor(Date.now() / 1000)
  };
  if (ath !== undefined) payload.ath = ath;

  const encoder = new TextEncoder();
  const signingInput =
    `${b64url(encoder.encode(JSON.stringify(header)))}.` +
    `${b64url(encoder.encode(JSON.stringify(payload)))}`;
  const signingKey = await crypto.subtle.importKey(
    'jwk', key.privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    signingKey,
    encoder.encode(signingInput)
  );
  return `${signingInput}.${b64url(new Uint8Array(signature))}`;
}

export async function exchangeBoundToken(
  code: string, verifier: string, clientId: string, redirectUri: string
): Promise<Response> {
  const key = loadDpopKey();
  if (!key) throw new Error('No DPoP key in this browser session.');
  const proof = await signDpopProof(key, 'POST', TOKEN_URL);
  const body = new URLSearchParams({
    grant_type: 'authorization_code', code, client_id: clientId, redirect_uri: redirectUri,
    code_verifier: verifier
  });
  return fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', DPoP: proof },
    body
  });
}

export async function readBookings(accessToken: string): Promise<Response> {
  const key = loadDpopKey();
  if (!key) throw new Error('No DPoP key in this browser session.');
  const htu = `${API_ORIGIN}/Api/rentals/Booking`;
  const ath = await sha256B64url(accessToken);
  const proof = await signDpopProof(key, 'GET', htu, ath);
  return fetch(htu, { headers: { Authorization: `DPoP ${accessToken}`, DPoP: proof } });
}
```

L’échange répond `token_type: "DPoP"` quand le serveur a accepté la
preuve. Le modèle de ce module est le client de référence fonctionnel
[e2e/fixtures/miniapp/index.html](https://github.com/wearefacet/facet/blob/main/e2e/fixtures/miniapp/index.html)
— PKCE plus DPoP en JavaScript vanilla, avec la fabrication des preuves
et le schéma d’autorisation `DPoP`.

## Dépannage

**`400` avec `DPoP htu mismatch`.** La preuve a signé la mauvaise
origine. Le message nomme les deux URLs. Signez l’origine configurée
plus le chemin, sans query ni fragment.

**`401` juste après la redirection, sans indice.** La clé a été perdue —
le `sessionStorage` a été vidé, ou le callback a tourné dans un autre
onglet. Générez une nouvelle clé et recommencez la connexion.

**`401` sur un appel qui marchait avant.** Un `jti` rejoué — le même
objet de preuve a servi deux fois. Forgez une preuve fraîche par
requête ; ne réutilisez jamais une chaîne de preuve.

**`401` avec un token lié valide.** Une vérification a échoué : `ath`
absent, `htm` ou `htu` faux, décalage expiré, ou schéma `Bearer`. Le
corps ne dit pas laquelle — revérifiez les claims de la preuve contre le
tableau ci-dessus.

**`401` avec un défi `WWW-Authenticate: Bearer`.** Le token n’est pas
lié. Abandonnez le schéma `DPoP`, ou reconnectez-vous avec une preuve à
l’échange.

## Voir aussi

- [Connecter les utilisateurs](/fr/build/apps/connect/user-login/) — le
  flux de connexion que cette page lie.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — le client du SDK et sa
  connexion `oauthBrowser`.
- [Mises à jour en direct](/fr/build/apps/data/realtime/) — un token lié
  ne voyage pas dans la négociation.
- Internes sur GitHub :
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
