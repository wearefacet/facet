---
title: "Connexion utilisateurà : OAuth 2.1 + PKCE"
description: Exécutez le flux complet de connexion par code d’autorisation + PKCE et traitez ses erreurs.
audience: [developer]
features: [APP-02, APP-05, FE-21]
sidebar:
  order: 4
verified_at: f1409cdc
---

Une app connecte un compte via l’écran de consentement de Facet. Il s’agit du
flux de code d’autorisation OAuth 2.1 avec PKCE (Proof Key for Code Exchange).
L’app envoie le navigateur vers `/OAuth/authorize`, le compte se connecte et
élit un rôle, puis Facet redirige vers l’app avec un code à usage unique que
celle-ci échange contre un token d’accès et un refresh token.

> **Pour les agentsà :** client public, sans secret. Fabriquez `code_verifier`
> (base64url aléatoire, 43 à 128 caractères) et
> `code_challenge = base64url(SHA-256(verifier))` ; gardez `verifier` et
> `state` dans `sessionStorage`. Naviguez vers `GET /OAuth/authorize` avec
> `response_type=code`, `client_id`, `redirect_uri`, `code_challenge`,
> `code_challenge_method=S256`, `state`. Au callback, vérifiez `state`, puis
> POSTez vers `/OAuth/token`, encodé en formulaireà : `grant_type=authorization_code`,
> `code`, `client_id`, `redirect_uri`, `code_verifier`. Réponseà :
> `access_token`, `token_type`, `expires_in`, `refresh_token`. Refreshà :
> `grant_type=refresh_token` avec le même `client_id` ; gardez 10 secondes
> entre deux refresh, sinon vous recevez `429 slow_down`.

## Quand l’utiliser

Utilisez cette page quandà :

- vous construisez une app web ou native qui connecte un compte via l’écran de
  consentement,
- vous avez besoin du va-et-vient de redirection : autorisation, consentement,
  callback, échange de token.

Un appelant purement backend passe plutôt par une clé d’API d’app —
voir [Apps backend](/fr/apps/service-accounts/).

## Avant de commencer

- Enregistrez l’app, publiez-la à l’état `active`, et enregistrez le
  `redirect_uri` exact que l’app présente — voir
  [Enregistrer une app](/fr/apps/registering-app/). La correspondance est
  exacte, avec une règle de port `*` pour les hôtes http loopback.
- Ajoutez l’origine de l’app à `allowed_origins`, pour que le navigateur puisse
  appeler le point de terminaison de token — voir
  [CORS et origines autorisées](/fr/apps/cors-origins/).
- Le compte qui se connecte doit porter au moins un rôle. L’écran de
  consentement liste les rôles que le compte détient.

## Étapes

Voici le va-et-vient de la connexion :

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

Fabriquez un `code_verifier` : une chaîne base64url aléatoire de 43 à 128
caractères (RFC 7636) ; le client de référence en utilise 64. Calculez
`code_challenge = base64url(SHA-256(code_verifier))`. La méthode `S256` est la
seule acceptéeà ; `plain` est refusée. Rangez `code_verifier` et `state` dans
`sessionStorage` — le callback doit les retrouver.

### 2. Envoyer le navigateur vers le point de terminaison d’autorisation

Naviguez vers `GET /OAuth/authorize` avec ces paramètresà :

| Paramètre | Valeur |
| --- | --- |
| `response_type` | `code` |
| `client_id` | l’id client de l’app |
| `redirect_uri` | l’adresse enregistrée, exactement telle qu’enregistrée |
| `code_challenge` | `base64url(SHA-256(code_verifier))` |
| `code_challenge_method` | `S256` |
| `state` | une valeur aléatoire que l’app vérifie au callback |

Sans session navigateur, le point de terminaison répond `302` vers
`/Login?redirectTo=…` avec l’URL d’autorisation passée en paramètreà ; la page
de connexion renvoie le navigateur vers l’URL d’autorisation après la
connexion. Avec une session, le point de terminaison redirige le navigateur
vers la route `/OAuthConsent`. L’écran de consentement s’affiche toujours — le
compte élit exactement un rôle pour l’appà ; il n’existe pas de consentement
silencieux.

### 3. Traiter le callback

Facet redirige vers `redirect_uri` avec `code` et `state` dans la requête.
Comparez `state` avec la valeur enregistrée par l’app avant la redirectionà ;
une différence signifie que la redirection ne vient pas de cette connexion.

### 4. Échanger le code au point de terminaison de token

POSTez le code vers `POST /OAuth/token`, avec un corps
`application/x-www-form-urlencoded` :

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=AUTH_CODE&client_id=CLIENT_ID&redirect_uri=REDIRECT_URI&code_verifier=VERIFIER
```

La réponse porte `access_token` (le JWT de l’app, signé avec ES256),
`token_type` (`"DPoP"` quand l’échange a porté une preuve DPoP, `"Bearer"`
sinon), `expires_in` (durée de vie du token d’accès en secondes —
`iam.jwt.access_token_ttl`, `900` par défaut) et `refresh_token`. Le token
n’est pas renouveléà : quand `expires_in` est écoulé, appelez le grant de
refresh à l’étape 6 avant le prochain appel d’API. Il n’y a pas de membre
`scope` — Facet ne déclare aucun vocabulaire de scopes. Ajoutez un en-tête
`DPoP` à l’échange pour lier le token à une clé — voir
[Liaison de token DPoP](/fr/apps/dpop/). Le grant `authorization_code` compte
30 échanges par `client_id` et par IP par fenêtre de 5 minutesà ; les refresh
sont exemptés.

### 5. Appeler l’API avec le token d’accès

Envoyez le token dans `Authorization: Bearer <access_token>`, ou avec le
schéma `DPoP` quand le token est lié. Le token est un JWT ES256 avec ces
claimsà :

| Claim | Valeur |
| --- | --- |
| `sub` | l’id du compte |
| `sid` | un id de session d’app frais |
| `role` | le nom du rôle élu |
| `app` | l’id de l’app |
| `typ` | `"app"` |

### 6. Renouveler la session

POSTez `grant_type=refresh_token` avec le `refresh_token` et le même
`client_id` :

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=REFRESH_TOKEN&client_id=CLIENT_ID
```

Le refresh token est lié au clientà : un `client_id` manquant ou différent
répond `401 invalid_grant` et laisse la session intacte. Chaque refresh relit
l’état réel — compte, rôle, statut de l’app et attributionà ; un contrôle en
échec révoque la session. Un refresh moins de 10 secondes après le précédent
répond `429 {"error": "slow_down"}` — attendez, puis réessayez. La réponse
porte un `access_token` frais et un nouveau `refresh_token`.

## Exemple

Ce module exécute tout le flux, en bearer seul. Réglez les constantes, servez
le fichier depuis l’origine de l’app, et appelez `startSignIn()` depuis un
bouton :

```ts
// facet-signin.ts — un client navigateur OAuth 2.1 + PKCE complet, modelé sur
// le client de référence e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.example.tld';
const CLIENT_ID = 'your-client-id';
const REDIRECT_URI = 'https://app.example.tld/oauth/callback'; // doit correspondre à un redirect_uri enregistré
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

Sur la page de callback, exécutez `handleCallback(location.href)` et stockez
les tokens renvoyés. Le modèle de ce module est le client de référence
fonctionnel
[e2e/fixtures/miniapp/index.html](https://github.com/wearefacet/facet/blob/main/e2e/fixtures/miniapp/index.html).

## Dépannage

Chaque erreur est un corps JSONà: `{"error": "<code>", "error_description": "<detail>"}`.

| Erreur | Où | Cause |
| --- | --- | --- |
| `invalid_request` | authorize, token | un paramètre est manquant ou mal formé |
| `access_denied` | authorize | le compte a refusé le consentement, ou le POST d’élection portait une valeur `role` mal formée |
| `invalid_grant` | token | mauvais `code_verifier` ; le code a expiré (TTL de 60 secondes) ; le code a déj à été consomméà ; l’app a été désactivée ou une attribution s’est resserrée entre l’autorisation et l’échangeà ; `client_id` faux ou manquant au refreshà ; réutilisation d’un refresh token |
| `slow_down` | token, refresh | `429` — un refresh moins de 10 secondes après le précédent |
| `unknown_client` | `GET /OAuth/client-info` | `404` — slug inconnu, ou l’app n’est pas active |

:::caution
Le POST de confirmation du consentement nomme le rôle élu dans un champ
`role`, avec la valeur qualifiée `iam.Roles.<name>`. Le payload du
consentement liste les rôles sous `role_id`. Un client de consentement écrit à

la main qui poste `role_id` reçoit `access_denied`.
:::

**Une `redirect_uri` qui ne correspond pas produit une page d’erreur, jamais
une redirection.** Facet refuse de rediriger vers une cible non validée.
Vérifiez l’adresse enregistréeà ; la correspondance est exacte en dehors de la
règle de port http loopback.

**`state` qui ne correspond pas après la redirection.** `sessionStorage` a
perdu la paire enregistrée — un nouvel onglet ou un rendu côté serveur ne la
partage pas. Gardez la tentative dans l’onglet qui a lancé la connexion.

**`invalid_grant` sur un code que vous croyez correct.** Le code est à usage
unique et expire après 60 secondes. Un gestionnaire de callback qui s’exécute
deux fois envoie un second échangeà ; seul le premier réussit.

**Chaque appel d’API répond `401` après que le token a fonctionné un moment.**
Le token d’accès a dépassé sa durée de vie `expires_in`. Renouvelez-le, puis
réessayez l’appel. Un refresh dans les 10 secondes qui suivent le précédent
répond `slow_down` — attendez, puis réessayez.

## Voir aussi

- [Liaison de token DPoP](/fr/apps/dpop/) — liez le token à une clé.
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/) —
  `oauthBrowser` exécute ce flux pour vous, y compris le délai minimal entre
  refresh.
- [Enregistrer une app](/fr/apps/registering-app/) — id client, adresses de
  redirection, origines.
- [Appsà : attributions ∩ rôles](/fr/concepts/apps-grants-roles/) — le rôle élu
  et les attributions bornent chaque requête.
- Internes sur GitHubà :
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
