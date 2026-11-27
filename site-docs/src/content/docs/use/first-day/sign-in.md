---
type: how-to
title: Sign in and secure your account
description: Sign in to Facet, set up multi-factor authentication (MFA), and reset your password.
audience: [user]
features: [FE-01, IAM-01, IAM-03, IAM-04, IAM-05, IAM-10]
sidebar:
  order: 2
verified_at: eee55a2
---

You sign in to Facet with your email address and your password. Your
organization can require a second check at sign-in: multi-factor
authentication (MFA). The sign-in screens call it two-factor authentication.
This page covers sign-in, first passwords, MFA, and password reset.

![The Facet sign-in screen with the email and password fields and the Sign in button.](/screens/use/first-day-sign-in-1.png)

## Before you start

- **First password.** It comes from your administrator: a temporary password
  or an invite link in an email.
- **Authenticator app.** For MFA you need an app. Facet works with apps such
  as 1Password, Authy, and Aegis.

## Steps

### 1. Open the sign-in page

Open the address your organization gives you. The page shows **Email**,
**Password**, and a **Sign in** button.

### 2. Enter your email and password

1. Type your email address in **Email**.
2. Type your password in **Password**.
3. Select **Sign in**.

When the password is wrong, Facet shows the attempts that remain: *"Invalid
credentials. 3 attempts remaining."* After too many failed tries, sign-in
locks for about 5 minutes.

### 3. Set your first password

Your first sign-in depends on the credential your administrator sent.

- **A temporary password.** Sign in with it. Facet shows *"Set a new
  password"*. Enter the current password, a new password with at least
  8 characters, and repeat the new password. Select **Save password and
  continue**. Facet signs you in with the new password.
- **An invite link.** Open the link from the email. The page shows *"Choose
  a new password"*. Enter a new password with at least 8 characters and
  select **Set password**. Facet signs you in.

![The Set a new password screen for an account with a temporary password.](/screens/build/run-facet-3.png)

### 4. Enter the code from your authenticator app

If your account has MFA, sign-in stops at the *"Two-factor authentication"*
screen.

1. Open your authenticator app.
2. Type the 6-digit code for Facet.
3. Select **Verify**.

The code changes every 30 seconds. If you cannot reach the app, select
**Use a backup code** and enter one of your saved codes.

### 5. Set up MFA when Facet asks

Facet can ask you to set up MFA during sign-in:

- **Your organization requires MFA.** Sign-in stops at *"Set up
  two-factor authentication"* until you finish. The screen offers no way
  back.
- **Your organization recommends MFA.** After sign-in, Facet shows the same
  setup. You can select **Skip for now**. Facet asks again at your next
  sign-in.

  To set up MFA:

1. Scan the QR code with your authenticator app. If you cannot scan, select
   **Copy secret to clipboard** and paste the key from **Manual entry key**
   into your app.
2. Type the 6-digit code from the app and select **Verify and enable**.
3. Facet shows 10 backup codes in the form `xxxx-xxxx`.
4. Save the codes in a safe place. Each code works once, when your
   authenticator is not available.
5. Select **I've saved my backup codes**.

:::caution
Facet shows the backup codes once. If you lose them and lose your
authenticator, an administrator must reset MFA for your account.
:::

:::note
You set up MFA at sign-in. The settings pages have no MFA section.
:::

### 6. Sign in with single sign-on

If your organization configured single sign-on (SSO), the sign-in page shows
one **Continue with** button per provider. Select your provider and follow
its steps. When the server requires SSO, the password fields and the
**Forgot password?** link do not show.

If the sign-in with the provider does not finish, Facet returns to the
sign-in page. Try again. If it fails again, contact your administrator.

### 7. Reset your password by email

You do not need to sign in to reset a password.

1. Open the sign-in page and select **Forgot password?**.
2. Type your email address in **Identifier**.
3. Select **Send reset link**.
4. Facet shows *"Check your inbox"* and the validity period of the link.
5. Open the email and select the link. Check the spam folder if the email
   does not arrive.
6. The page shows *"Choose a new password"*. Type a new password with at
   least 8 characters and select **Set password**.
7. Facet returns to the sign-in page and shows *"Password updated. Sign in
   with your new password."*

### 8. Sign out

1. Select your name at the bottom of the sidebar.
2. Select **Logout**.

Your session also ends when it expires (14 days by default), when you revoke
it in your settings, or when Facet detects a reused session token. See
[Your settings and API keys](/use/account/) to review your sessions.

## Troubleshooting

### The password does not work

1. Check the email address and the password for typing errors.
2. Check that Caps Lock is off. The error message shows the attempts that
   remain.
3. Wait and try again. After too many failed tries, sign-in locks for about
   5 minutes.

### The code does not work

Wait for a fresh code and enter it at once. A code that you already used
does not work again. After 5 wrong codes, sign-in locks for about
5 minutes.

### You lost your authenticator

1. Select **Use a backup code** on the *"Two-factor authentication"* screen.
2. Enter one of the codes you saved. Each code works once.
3. Ask an administrator to reset MFA. Then sign in and set up MFA again.

### The code step expired

The code step stays open for 5 minutes. When it closes, Facet shows
*"Verification session expired. Please sign in again."* Start again and
enter a fresh code.

### The reset link does not work

A link works once and expires after 24 hours by default. When Facet shows
*"This reset link is invalid or has expired."*, request a new link. Select
**Forgot password?** on the sign-in page. A new link replaces an older
link.

### No reset email arrived

Check the spam folder. Facet shows the same confirmation for every address.
It cannot tell you whether the account exists. If no email arrives, ask your
administrator.

## Related

- [The dashboard](/use/first-day/dashboard/) — the first page after
  sign-in.
- [Your settings and API keys](/use/account/) — review your active sessions
  and create API keys.
- [Roles: who sees and does what](/discover/how-it-works/roles/) — why the
  role you sign in as decides what you see.
- [Security](/discover/security/) — how Facet protects accounts, sessions,
  and secrets.
