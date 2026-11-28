---
type: how-to
title: "Connexion utilisateur : OAuth 2.1 + PKCE"
description: Exécutez le flux OAuth 2.1 par code d’autorisation avec PKCE, de l’écran de consentement au renouvellement du token.
audience: [developer]
features: [APP-02, APP-05, FE-21]
sidebar:
  order: 1
verified_at: eee55a2
---

Votre app navigateur connecte les personnes de Brightwater par Facet, et l’app ne voit jamais un mot de passe. Le flux suit OAuth 2.1 : le code d’autorisation avec PKCE (Proof Key for Code Exchange). L’app envoie le navigateur vers `/OAuth/authorize`. Le compte se connecte et élit un rôle. Facet redirige vers l’app avec un code à usage unique, que l’app échange contre un access token et un refresh token.

> **Pour les agents :** client public, sans secret. Fabriquez `code_verifier` (base64url aléatoire, 43 à 128 caractères) et `code_challenge = base64url(SHA-256(verifier))` ; gardez `verifier` et `state` dans `sessionStorage`. Naviguez vers `GET /OAuth/authorize` avec `response_type=code`, `client_id`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `state`. Au callback, vérifiez `state`, puis POSTez vers `/OAuth/token`, encodé en formulaire : `grant_type=authorization_code`, `code`, `client_id`, `redirect_uri`, `code_verifier`. Réponse : `access_token`, `token_type`, `expires_in`, `refresh_token`. Refresh : `grant_type=refresh_token` plus le même `client_id` ; gardez 10 secondes entre deux refresh, sinon vous recevez `429 slow_down`.

## Quand l’utiliser

Utilisez cette page quand :

- vous construisez une app navigateur ou native qui connecte un compte via l’écran de consentement ;
- vous avez besoin du va-et-vient de redirection : autorisation, consentement, callback, échange de token.

Un appelant purement backend utilise plutôt une clé d’API propre à l’app — voir [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/).

## Avant de commencer

- Enregistrez l’app, publiez-la à `active`, et enregistrez le `redirect_uri` exact que l’app présente — voir [Enregistrer une app](/fr/build/apps/connect/register/). La correspondance est exacte, plus une règle de port `*` sur les hôtes http de loopback.
- Ajoutez l’origine de l’app à `allowed_origins`, pour que le navigateur puisse appeler le endpoint de token — voir [CORS et origines autorisées](/fr/build/apps/connect/cors/).
- Le compte qui se connecte doit détenir au moins un rôle. L’écran de consentement liste les rôles du compte qui couvrent les attributions requises de l’app.

## Étapes

Voici le va-et-vient de connexion :

<!-- d2
direction: down
pkce: "App builds the PKCE pair" {class: external}
authorize: "Browser opens /OAuth/authorize"
session: "Browser session present?" {class: decision}
login: "302 to /Login"
signin: "Account signs in"
consent: "302 to /OAuthConsent"
elect: "Consent posts the election"
redirect: "302 to redirect_uri with code and state"
token: "App POSTs /OAuth/token with the verifier"
calls: "App stores tokens and calls the API" {class: ok}

pkce -> authorize
authorize -> session
session -> login: no
login -> signin
signin -> authorize
session -> consent: yes
consent -> elect: account elects one role
elect -> redirect
redirect -> token
token -> calls
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/500212d3-light.svg" alt="App builds the PKCE pair" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/500212d3-dark.svg" alt="App builds the PKCE pair" loading="lazy" />
</div>

### 1. Générer la paire PKCE

Fabriquez un `code_verifier` : une chaîne base64url aléatoire de 43 à 128 caractères (RFC 7636) ; le client de référence en utilise 64. Calculez `code_challenge = base64url(SHA-256(code_verifier))`. La méthode `S256` est la seule acceptée ; `plain` est refusée. Enregistrez `code_verifier` et `state` dans `sessionStorage` — le callback doit les retrouver.

Depuis un terminal, la paire ressemble à ceci :

```sh
openssl rand -base64 48 | tr '+/' '-_' | tr -d '='
# YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F  <- code_verifier

printf '%s' 'YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
# JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc  <- code_challenge
```

### 2. Envoyer le navigateur vers le endpoint d’autorisation

Naviguez vers `GET /OAuth/authorize` avec ces paramètres :

| Paramètre | Valeur |
| --- | --- |
| `response_type` | `code` |
| `client_id` | le client id de l’app |
| `redirect_uri` | l’adresse enregistrée, exactement telle qu’enregistrée |
| `code_challenge` | `base64url(SHA-256(code_verifier))` |
| `code_challenge_method` | `S256` |
| `state` | une valeur aléatoire que l’app vérifie au callback |

Sans session navigateur, le endpoint répond `302` vers `/Login?redirectTo=…` avec l’URL d’autorisation incrustée ; la page de connexion ramène le navigateur vers l’URL d’autorisation après la connexion. Avec une session, le endpoint redirige le navigateur vers la route `/OAuthConsent`. L’écran de consentement s’affiche toujours — le compte élit exactement un rôle pour l’app ; il n’y a pas de consentement silencieux.

L’écran se construit à partir d’un payload JSON que la page récupère. Pour l’app de check-out de Brightwater, le payload de Ravi se lit :

```json
{
  "app": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "slug": "brw-checkout",
    "display_name": "Brightwater Check-out",
    "description": "The warehouse check-out board: today's bookings, with the items each booking needs. Marks items out and back in.",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "status": "active"
  },
  "roles": [
    {
      "role_id": "iam.Roles.admin",
      "display_name": "Full administrative access to all resources.",
      "effective_scope": [
        { "target": "rentals.Booking", "actions": ["read"] },
        { "target": "rentals.BookingLine", "actions": ["read"] },
        { "target": "equipment.Item", "actions": ["read", "create", "update"] }
      ]
    }
  ],
  "state": "winter-fair-43",
  "requested_scope": null
}
```

Chaque entrée sous `roles` est un rôle que le compte peut élire, avec `effective_scope` montrant ce que l’app garderait pour ce rôle — l’attribution ∩ le rôle, calculé en direct. Un rôle qui ne couvre aucune action d’attribution requise de l’app n’apparaît pas du tout.

### 3. Traiter le callback

Facet redirige vers `redirect_uri` avec `code` et `state` dans la query. Comparez `state` avec la valeur que l’app a enregistrée avant la redirection ; une divergence signifie que la redirection ne vient pas de cette connexion.

### 4. Échanger le code au endpoint de token

POSTez le code vers `POST /OAuth/token`, avec un corps `application/x-www-form-urlencoded` :

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=AUTH_CODE&client_id=CLIENT_ID&redirect_uri=REDIRECT_URI&code_verifier=VERIFIER
```

La réponse porte `access_token` (le JWT de l’app, signé en ES256), `token_type` (`"DPoP"` quand l’échange portait une preuve DPoP, `"Bearer"` sinon), `expires_in` (durée de vie de l’access token en secondes — `iam.jwt.access_token_ttl`, défaut `900`), et `refresh_token`. Le token n’est pas renouvelé : quand `expires_in` est écoulé, lancez le renouvellement à l’étape 6 avant le prochain appel d’API. Il n’y a pas de membre `scope` — Facet ne déclare aucun vocabulaire de scope. Ajoutez un en-tête `DPoP` à l’échange pour lier le token à une clé — voir [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/). Le grant `authorization_code` compte 30 échanges par `client_id` et IP par fenêtre de 5 minutes ; les renouvellements sont exemptés.

L’échange de la connexion du pas-à-pas a répondu :

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc0RlY5Q05RSDNLOThFTURTTUFBWjkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDAxNjEsImV4cCI6MTc5NTcwMTA2MSwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.AqrsiB6iDvRCasWYNdlauDPTOuXSBERFmV-baW1aAlgd-HUxXI7s81PiDBFEBcognYPtyDM5tGieS5-OvXafAw",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.a91913d305aac321675056fd92fb5cf4be2e3827209e79cdf140f548f4b1538d"
}
```

### 5. Appeler l’API avec l’access token

Envoyez le token dans `Authorization: Bearer <access_token>`, ou avec le schéma `DPoP` quand le token est lié. Le token est un JWT ES256 avec ces claims — le payload du token ci-dessus, décodé :

| Claim | Valeur |
| --- | --- |
| `sub` | l’id du compte — `06H1FM098WB2B7X5BA49466K4N` |
| `sid` | un id de session d’app neuf — `42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a` |
| `role` | le rôle élu — `iam.Roles.admin` |
| `app` | l’id de l’app — `06H1FQF7NGDJJKSNHXPYT6627M` |
| `typ` | `"app"` |
| `jti`, `iat`, `exp` | l’id du token, l’émission et l’expiration (900 secondes après `iat`) |

### 6. Renouveler la session

POSTez `grant_type=refresh_token` avec le `refresh_token` et le même `client_id` :

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=REFRESH_TOKEN&client_id=CLIENT_ID
```

Le refresh token est lié au client : un `client_id` manquant ou différent répond `401 invalid_grant` et laisse la session intacte. Chaque renouvellement relit l’état réel — compte, rôle, statut de l’app et attribution ; un contrôle en échec révoque la session. Un renouvellement à moins de 10 secondes du précédent répond `429 {"error": "slow_down"}` — attendez, puis réessayez. La réponse porte un `access_token` neuf et un `refresh_token` roté :

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc1SDVLODdETjNRRDZWN0hWVlpEWFkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDA0MzQsImV4cCI6MTc5NTcwMTMzNCwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.OXS2AmjdTMDFOl_IPfa77j-lbGOPZ7formHoF4SxIHzUuItfLCbCh64-Cz_ffA4EUkAYiVHIcDOxB9mFhSinuA",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.8a10cdea40171e71c96fc7eaaab8ed1aabd11a84cf0a2b9c1d3783bf26a44790"
}
```

Même `sid`, `jti` neuf — la session continue, le token a tourné.

## Exemple

Ce module exécute tout le flux, en bearer seul. Réglez les constantes, servez le fichier depuis l’origine de l’app, et appelez `startSignIn()` depuis un bouton :

```ts
// facet-signin.ts — un client navigateur OAuth 2.1 + PKCE complet, calqué sur
// le client de référence e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.localhost:3443';
const CLIENT_ID = '06H1FQF7NG357EQ0P348Z2BEV5';
const REDIRECT_URI = 'http://localhost:5173/auth/callback'; // doit égaler un redirect_uri enregistré
const AUTHORIZE_PATH = '/OAuth/authorize';
const TOKEN_PATH = '/OAuth/token';
const STORAGE_KEY = 'facet.signin';

interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token: string;
}

function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomB64url(characters: number): string {
  const bytes = new Uint8Array(characters);
  crypto.getRandomValues(bytes);
  return b64url(bytes).slice(0, characters);
}

async function sha256B64url(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return b64url(new Uint8Array(digest));
}

export async function startSignIn(): Promise<void> {
  const verifier = randomB64url(64);
  const state = randomB64url(16);
  const challenge = await sha256B64url(verifier);
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ verifier, state }));

  const url = new URL(AUTHORIZE_PATH, API_ORIGIN);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', CLIENT_ID);
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('code_challenge', challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('state', state);
  location.assign(url.toString());
}

export async function handleCallback(redirectUrl: string): Promise<TokenResponse> {
  const query = new URLSearchParams(new URL(redirectUrl).search);
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (query.get('code') === null || raw === null) {
    throw new Error('No sign-in attempt found in this browser session.');
  }
  const attempt = JSON.parse(raw) as { verifier: string; state: string };
  if (attempt.state !== query.get('state')) {
    throw new Error('State mismatch — the redirect did not come from this sign-in.');
  }

  const body = new URLSearchParams({
    grant_type: 'authorization_code', code: query.get('code')!, client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI, code_verifier: attempt.verifier
  });
  const response = await fetch(`${API_ORIGIN}${TOKEN_PATH}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  const payload = await response.json();
  if (!response.ok) {
    const detail = `${payload.error ?? ''} ${payload.error_description ?? ''}`.trim();
    throw new Error(`Token exchange failed (HTTP ${response.status}): ${detail}`);
  }
  sessionStorage.removeItem(STORAGE_KEY);
  return payload as TokenResponse;
}
```

Sur la page de callback, exécutez `handleCallback(location.href)` et stockez les tokens renvoyés. Le modèle de ce module est le client de référence fonctionnel [e2e/fixtures/miniapp/index.html](https://github.com/wearefacet/facet/blob/main/e2e/fixtures/miniapp/index.html).

## Dépannage

Chaque erreur est un corps JSON : `{"error": "<code>", "error_description": "<detail>"}`.

| Erreur | Où | Cause |
| --- | --- | --- |
| `invalid_request` | authorize, token | un paramètre manque ou est mal formé |
| `access_denied` | authorize | le compte a refusé le consentement, ou le POST d’élection portait une valeur `role` mal formée |
| `invalid_grant` | token | `code_verifier` erroné ; le code a expiré (TTL de 60 secondes) ; le code a déjà été consommé ; l’app a été désactivée ou une attribution s’est resserrée entre l’autorisation et l’échange ; `client_id` erroné ou manquant au renouvellement ; réutilisation du refresh token |
| `slow_down` | token, refresh | `429` — un renouvellement à moins de 10 secondes du précédent |
| `unknown_client` | `GET /OAuth/client-info` | `404` — slug inconnu, ou l’app n’est pas active |

:::caution
Le POST de confirmation du consentement nomme le rôle élu dans un champ `role`, avec la valeur qualifiée `iam.Roles.<name>`. Le payload de consentement liste les rôles sous `role_id`. Un client de consentement écrit à la main qui POSTe `role_id` reçoit `access_denied`.
:::

**Une divergence de `redirect_uri` affiche une page d’erreur, jamais une redirection.** Facet refuse de rediriger vers une cible non validée. Vérifiez l’adresse enregistrée ; la correspondance est exacte hors de la règle de port http de loopback.

**Divergence de `state` après la redirection.** `sessionStorage` a perdu la paire enregistrée — un nouvel onglet ou un rendu côté serveur ne la partage pas. Gardez la tentative dans l’onglet qui a lancé la connexion.

**`invalid_grant` sur un code que vous croyez correct.** Le code est à usage unique et expire après 60 secondes. Un gestionnaire de callback qui s’exécute deux fois envoie un second échange ; seul le premier réussit :

```json
{"error": "invalid_grant", "error_description": "Authorization code is invalid, expired, or already used"}
```

Relancez la connexion.

**L’écran de consentement ne liste aucun rôle pour ce compte.** Les rôles du compte ne couvrent pas les actions d’attribution requises de l’app — vérifiez quelles actions les attributions marquent `required: true`, et quelles lignes les rôles portent. Un administrateur peut élargir un rôle ou resserrer les attributions de l’app — voir [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/).

**Chaque appel d’API répond `401` après que le token a fonctionné un moment.** L’access token a dépassé sa durée de vie `expires_in`. Renouvelez-le, puis réessayez l’appel. Un renouvellement dans les 10 secondes suivant le précédent répond `slow_down` — attendez, puis réessayez.

## Voir aussi

- [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/) — liez le token à une clé.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — `oauthBrowser` exécute ce flux pour vous, y compris le plancher de renouvellement.
- [Enregistrer une app](/fr/build/apps/connect/register/) — client id, adresses de redirection, origines.
- [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/) — le rôle élu et les attributions bornent chaque requête.
- Sources internes sur GitHub : [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
