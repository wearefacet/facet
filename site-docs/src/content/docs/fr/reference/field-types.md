---
title: Types de champs
description: Chaque type de champ, avec sa validation, sa normalisation et ses opérateurs de filtre.
audience: [author, developer]
features: [DOM-04, DOC-13]
sidebar:
  order: 3
verified_at: 008dd880
---

> Généré depuis `src/doctype/field_types/` par `make gen-docs-field-types`. Ne modifiez pas ce fichier à la main.

Cette page sert à choisir un type de champ et à vérifier comment il valide, normalise et filtre.

Un champ de doctype déclare l'un des types ci-dessous. Le générateur lit le registre des types et le compileur de filtres ; la formulation de la validation et de la normalisation se maintient dans le générateur.

- **Normalisation** s'exécute avant la validation à chaque create et update.
- **Opérateurs de filtre** liste les suffixes que les routes de liste servent pour le type ; la page [opérateurs de filtre](/fr/reference/filter-operators/) donne à chacun sa signification.

| Type | Validation | Normalisation | Opérateurs de filtre |
|---|---|---|---|
| `any` | Accepts any JSON value. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `array` | JSON array. Every non-null item validates against the declared `items` type; the definition must declare `items`. | Applies the `items` type normalization to every non-null item. | `contains`, `eq`, `overlaps` |
| `boolean` | JSON boolean (`true` or `false`). | None. | `eq`, `ne` |
| `color` | String in an accepted color form: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()`/`rgba()`, or `hsl()`/`hsla()`. | Rewrites the value to its canonical `#RRGGBBAA` form; alpha defaults to `FF`. Unparseable values pass through unchanged so validation rejects them. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `data` | Client input is always rejected: the field is computed server-side (read-only). | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `date` | String in `YYYY-MM-DD` form that names a real calendar date. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `dateperiod` | Object with `start` and `end`; both bounds are ISO dates (`YYYY-MM-DD`); start may equal end. | None. | `contains`, `eq`, `overlaps`, `within` |
| `datetime` | String parseable as ISO 8601 datetime; the input carries an explicit offset (or `Z`). | Converts the value to UTC RFC 3339 form (`...Z`). | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `dictionary` | Object with string keys. Every non-null value validates against the declared `values` type; the definition must declare `values`. | Applies the `values` type normalization to every non-null value. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `duration` | Non-negative integer (seconds). | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `enum` | String equal to one of the declared `values` keys. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `file` | String holding a 26-character ULID (Crockford Base32) — an artifact id. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `integer` | 64-bit integer; honors the declared `min` and `max`. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `longtext` | String; honors the declared `min` and `max` length bounds and `pattern` (same rules as `string`). | Rewrites `\r\n` and bare `\r` to `\n` before validation. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `money` | Object with a decimal-string `value` and a `currency` ticker registered in the currency registry. | Fills the `currency` member from the field's declared default currency when the payload omits it. | `between`, `currency`, `eq`, `gt`, `gte`, `lt`, `lte` |
| `object` | Object. Validates against the declared `properties` sub-schema: unknown keys are rejected and required sub-fields are enforced. Free-form when the definition declares no `properties`. | Applies each declared `properties` type normalization to the matching sub-values. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `period` | Object with `start` and `end`; both bounds are ISO datetimes with a time component; start is strictly before end. | Converts both bounds to UTC RFC 3339 form. | `contains`, `eq`, `overlaps`, `within` |
| `phone` | Non-empty string (deliberately loose: number formats vary by locale). | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `reference` | Qualified document id `{domain}.{Doctype}.{id}` whose prefix matches the declared target doctype, or the URN form `urn:facet:{domain}:{Doctype}:{id}`. `null` unsets. A collection field validates each element. | Converts the URN form to the dotted storage form; qualifies a bare id with the declared target doctype. Collection elements are qualified in turn. | `eq`, `ne` |
| `secret` | A stage handle (`sh_` plus a 26-character ULID), a marker object `{mode, version, set_at}`, or `null`. Plaintext is never accepted in content. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `string` | String; honors the declared `min` and `max` length bounds and `pattern`. | None. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |
| `url` | Absolute `http(s)` URL whose host is a DNS-style name or a bracketed IPv6 literal. | Completes a scheme-less dotted host (for example `www.acme.tld`) with `https://`. | `between`, `eq`, `gt`, `gte`, `in`, `lt`, `lte`, `match`, `ne`, `starts_with` |

## Voir aussi

- [Types de champs (guide)](/fr/build/field-types/)
- [Concevoir des doctypes](/fr/build/designing-doctypes/)
- [Opérateurs de filtre](/fr/reference/filter-operators/)
