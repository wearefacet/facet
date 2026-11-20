---
title: Schéma de définition de doctype
description: "Chaque clé acceptée par la définition d’un doctype, avec son type, son statut obligatoire et son rôle."
audience: [author, developer]
features: [DOM-03]
sidebar:
  order: 10
verified_at: 008dd880
---

> Généré depuis `src/doctype` par `make gen-docs-doctype-schema`. Ne modifiez pas ce fichier à la main.

Cette page sert à vérifier les clés qu’accepte une définition de doctype.

Une définition de doctype est le document JSON qui enregistre un type de document. Le parseur sous `src/doctype/` accepte exactement les clés ci-dessous et refuse toute autre clé avec un 422. Les définitions peuvent aussi s’écrire en YAML ; le chargeur le convertit dans la même grammaire JSON.

## Clés de premier niveau

| Clé | Type | Obligatoire | Rôle |
| --- | --- | --- | --- |
| `doctype` | string | yes | CamelCase type name, e.g. WorkOrder. |
| `domain` | string | yes | Owning domain. Lowercase with dashes; a draft domain may carry the `_` prefix. |
| `schema_version` | integer | no | Breaking-change version, minimum 1. Drives lazy migration on read. Defaults to 1. |
| `aggregate_root` | boolean | no | True for an aggregate root. Defaults to false. |
| `member_of` | string | no | CamelCase parent doctype when this type is an owned child. |
| `description` | string | no | What the doctype represents. |
| `label` | string | no | Display label the interface shows. Falls back to the doctype name. |
| `icon` | string | no | Lucide icon identifier. Falls back to the default diamond mark. |
| `color` | string | no | CSS hex accent color, e.g. #1565C0. |
| `plural_label` | string | no | Human plural label for consent previews and client snippets. |
| `sensitive` | boolean | no | Highlights grants on this doctype in the permissions editor and consent preview. |
| `nav_visible` | boolean | no | Shows an owned child in the sidebar as a top-level entry. |
| `fields` | object | no | Field definitions keyed by field name. |
| `actions` | object | no | Named actions keyed by action name. Each maps to a Lua export function. |
| `children` | object | no | Composition children keyed by relationship name. Stored as separate projection rows. |
| `sidecar` | boolean | no | True for a system-managed attachment doctype in the core domain. |
| `sidecars` | object | no | Sidecar attachments on a host doctype, keyed by route segment. |
| `surface` | string | no | Custom-surface id on a sidecar doctype. The frontend resolves it through its surface registry. |
| `search` | string | no | Jinja2 template rendered into the trigram-search corpus at mutation time. |
| `display_name` | string | no | Jinja2 template rendered into the projection display label at mutation time. |
| `migrations` | object | no | Source schema version mapped to a Lua migration function name. |
| `script` | string | no | Lua script source with the lifecycle hooks, actions, and migrations. |
| `scopes` | object | no | Named predicates over the doctype's own fields. Permissions reference them as $name. |
| `identifier` | object | no | Sequential identifier configuration. When absent, document ids are ULIDs. |

## Schéma JSON

Le schéma exprime les ensembles de clés, les clés obligatoires, les motifs et les énumérations que le code applique. Les règles que le schéma ne peut pas exprimer suivent.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Facet doctype definition",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "doctype",
    "domain"
  ],
  "properties": {
    "doctype": {
      "type": "string",
      "pattern": "^[A-Z][a-zA-Z0-9]*$"
    },
    "domain": {
      "type": "string",
      "pattern": "^[a-z_][a-z0-9_\\-]*$"
    },
    "schema_version": {
      "type": "integer",
      "minimum": 1
    },
    "aggregate_root": {
      "type": "boolean"
    },
    "member_of": {
      "type": "string",
      "pattern": "^[A-Z][a-zA-Z0-9]*$"
    },
    "description": {
      "type": "string"
    },
    "label": {
      "type": "string"
    },
    "icon": {
      "type": "string"
    },
    "color": {
      "type": "string"
    },
    "plural_label": {
      "type": "string"
    },
    "sensitive": {
      "type": "boolean"
    },
    "nav_visible": {
      "type": "boolean"
    },
    "fields": {
      "type": "object",
      "additionalProperties": {
        "$ref": "#/$defs/field"
      }
    },
    "actions": {
      "type": "object",
      "propertyNames": {
        "not": {
          "enum": [
            "create",
            "delete",
            "history",
            "migrate",
            "rollback",
            "snapshot",
            "update",
            "validate"
          ]
        }
      },
      "additionalProperties": {
        "$ref": "#/$defs/action"
      }
    },
    "children": {
      "type": "object",
      "additionalProperties": {
        "$ref": "#/$defs/childrenEntry"
      }
    },
    "sidecar": {
      "type": "boolean"
    },
    "sidecars": {
      "type": "object",
      "additionalProperties": {
        "$ref": "#/$defs/sidecarRef"
      }
    },
    "surface": {
      "type": "string"
    },
    "search": {
      "type": "string"
    },
    "display_name": {
      "type": "string"
    },
    "migrations": {
      "type": "object",
      "additionalProperties": {
        "type": "string"
      }
    },
    "script": {
      "type": "string"
    },
    "scopes": {
      "type": "object",
      "additionalProperties": {
        "$ref": "#/$defs/scope"
      }
    },
    "identifier": {
      "$ref": "#/$defs/identifier"
    }
  },
  "$defs": {
    "field": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "type": {
          "enum": [
            "any",
            "array",
            "boolean",
            "color",
            "data",
            "date",
            "dateperiod",
            "datetime",
            "dictionary",
            "duration",
            "enum",
            "file",
            "integer",
            "longtext",
            "money",
            "object",
            "period",
            "phone",
            "reference",
            "secret",
            "string",
            "url"
          ]
        },
        "values": {
          "oneOf": [
            {
              "type": "array",
              "items": {
                "oneOf": [
                  {
                    "$ref": "#/$defs/enumValue"
                  },
                  {
                    "type": "string",
                    "minLength": 1
                  }
                ]
              }
            },
            {
              "$ref": "#/$defs/field"
            }
          ]
        },
        "items": {
          "$ref": "#/$defs/field"
        },
        "properties": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/$defs/field"
          }
        },
        "doctype": {
          "type": "string"
        },
        "required": {
          "type": "boolean"
        },
        "unique": {
          "type": "boolean"
        },
        "default": {},
        "min": {
          "type": "integer"
        },
        "max": {
          "type": "integer"
        },
        "collection": {
          "type": "boolean"
        },
        "compute": {
          "type": "string"
        },
        "compute_when": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "replicate": {
          "$ref": "#/$defs/replicate"
        },
        "on_source_delete": {
          "enum": [
            "keep",
            "unset"
          ]
        },
        "accept": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "title": {
          "type": "string"
        },
        "description": {
          "type": "string"
        },
        "write_only": {
          "type": "boolean"
        },
        "read_only": {
          "type": "boolean"
        },
        "owned": {
          "type": "boolean"
        },
        "filter": {
          "type": "object"
        },
        "dangling": {
          "type": "boolean"
        },
        "tags": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "pattern": {
          "type": "string"
        },
        "pattern_flags": {
          "type": "string"
        },
        "mode": {
          "type": "string"
        },
        "ttl_seconds": {
          "type": "integer"
        },
        "filters": {
          "type": "array",
          "items": {
            "enum": [
              "comparison",
              "currency",
              "equality",
              "interval",
              "membership",
              "text_search"
            ]
          }
        },
        "currency": {
          "type": "string"
        },
        "precision": {
          "type": "integer"
        },
        "operators": {
          "type": "array",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "enumValue": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "key"
      ],
      "properties": {
        "key": {
          "type": "string",
          "minLength": 1
        },
        "label": {
          "type": "string"
        },
        "color": {
          "type": "string"
        }
      }
    },
    "action": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "args": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/$defs/actionArg"
          }
        },
        "event_name": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9_]*$"
        },
        "description": {
          "type": "string"
        },
        "states": {
          "type": "object",
          "minProperties": 1,
          "additionalProperties": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "string",
              "minLength": 1
            }
          }
        }
      }
    },
    "actionArg": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "type"
      ],
      "properties": {
        "type": {
          "enum": [
            "any",
            "array",
            "boolean",
            "color",
            "data",
            "date",
            "dateperiod",
            "datetime",
            "dictionary",
            "duration",
            "enum",
            "file",
            "integer",
            "longtext",
            "money",
            "object",
            "period",
            "phone",
            "reference",
            "secret",
            "string",
            "url"
          ]
        },
        "required": {
          "type": "boolean"
        },
        "default": {},
        "values": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "min": {
          "type": "integer"
        },
        "max": {
          "type": "integer"
        },
        "doctype": {
          "type": "string"
        },
        "collection": {
          "type": "boolean"
        }
      }
    },
    "childrenEntry": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "doctype"
      ],
      "properties": {
        "doctype": {
          "type": "string",
          "pattern": "^[A-Z][a-zA-Z0-9]*$"
        },
        "collection": {
          "type": "boolean"
        },
        "description": {
          "type": "string"
        }
      }
    },
    "sidecarRef": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "doctype"
      ],
      "properties": {
        "doctype": {
          "type": "string",
          "pattern": "\\."
        },
        "column": {
          "type": "string"
        },
        "order": {
          "type": "integer"
        },
        "label": {
          "type": "string"
        }
      }
    },
    "scope": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "description": {
          "type": "string"
        },
        "where": {
          "type": "object",
          "additionalProperties": {
            "oneOf": [
              {
                "type": "string"
              },
              {
                "type": "number"
              },
              {
                "type": "boolean"
              }
            ]
          }
        }
      }
    },
    "replicate": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "field",
        "via"
      ],
      "properties": {
        "via": {
          "type": "string",
          "minLength": 1
        },
        "field": {
          "type": "string",
          "minLength": 1
        }
      }
    },
    "identifier": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "template"
      ],
      "properties": {
        "template": {
          "type": "string",
          "minLength": 1
        },
        "genonly": {
          "type": "boolean"
        }
      }
    }
  }
}
```

## Règles que le schéma ne peut pas exprimer

| Règle | Ce qu’elle implique | Sources |
| --- | --- | --- |
| Reserved action names | An action cannot use one of the reserved names: create, delete, history, migrate, rollback, snapshot, update, validate. | `doctype_definition.cr, validation.cr` |
| Action and child name collision | An action name cannot equal a child relationship name, in either direction. | `validation.cr (validate_actions)` |
| Actions and migrations need a script | Declared actions or migrations without a script are rejected. | `validation.cr (validate_script)` |
| Aggregation pair | aggregate_root: true contradicts member_of. A doctype is a root or a member, not both. | `validation.cr (validate_aggregation)` |
| compute keys only on data | compute and compute_when are rejected on every field type except data (secret fields get their own message). | `validation.cr (validate_compute_field_type)` |
| compute_when triggers | Each trigger must name a field of the doctype or a child relationship. | `validation.cr (validate_compute_when)` |
| Replicated field consistency | on_source_delete applies only to a field that carries replicate; its value must be keep or unset; a replica cannot be computed, required, or unique; the via field must exist and must be a reference field. | `validation.cr (validate_replicate_schema)` |
| Secret placement | A secret leaf is allowed at top level and inside object properties only, never inside arrays or dictionaries. A secret root must not appear in the search or display_name templates. Secret cannot be an action argument type. | `validation.cr (validate_secret_fields)` |
| Template roots | Every search and display_name root variable must be a declared field or a reserved variable: content always, display_name in search templates only. A display_name template must not reference the display_name column. | `validation.cr (validate_template)` |
| Reserved field names | A field cannot use one of the reserved names: created_at, deleted_at, display_name, id, links, parent_id, search, state, updated_at, version. | `validation.cr (RESERVED_FIELD_NAMES)` |
| Field name shape | A field name is lower_case_with_underscores or camelCase. | `validation.cr (validate_field_names)` |
| read_only and write_only | The two flags are mutually exclusive on one field. | `validation.cr (validate_field_names)` |
| Filter capability matrix | A declared filter capability must be valid for the field type: equality, comparison, text_search, interval, membership, and currency each cover their own type set. | `validation.cr (validate_field_filters), filter_capability.cr` |
| Sidecar shape | A sidecar doctype lives in the core domain and carries a target reference field that is required, read_only, and has no default. surface is only meaningful with sidecar: true and must be a lowercase identifier. | `validation.cr (validate_sidecar, validate_sidecar_surface)` |
| Sidecar segments | A sidecars segment is a lowercase identifier, does not collide with a children key, and names a non-empty column. | `validation.cr (validate_sidecars_keys)` |
| Children targets | A children doctype is a bare CamelCase name in the same domain. A domain prefix is rejected. | `validation.cr (validate_children)` |
| Draft versus live domains | The `_`-prefixed domain form is valid only in draft domains. A live domain cannot start with a digit or carry `_`. | `validation.cr (validate_domain_name, validate_domain_name_draft)` |
| Migration gaps | On update, every version below schema_version needs a migrations entry whose function name is non-empty; version keys are integers below schema_version. | `validation.cr (validate_migrations)` |
| identifier template | identifier.template must compile through the sequence generator: valid variables, at least one # group, group width within limits. | `validation.cr (validate_identifier)` |
| Empty text is absent | An optional text key parses an empty string as absent. No consumer handles "" beside nil. | `doctype_definition.cr (optional_string)` |
| Closed key sets | Every object level rejects unknown keys with 422. The sets are the KNOWN_KEYS constants this page is generated from. | `doctype_definition.cr, field_definition.cr, action_definition.cr, children_definition.cr, sidecar_ref.cr, named_scope.cr, replicate_config.cr` |
| Derived operators member | operators on a field is accepted on read and re-derived from filters. It is never stored. | `field_definition.cr` |

## Voir aussi

- [Concevoir des doctypes](/fr/build/designing-doctypes/) — comment modéliser un domaine avec ces clés.
- [Faire évoluer un schéma](/fr/build/evolving-schema/) — versions de schéma et migrations.
- [Composition parent et enfant](/fr/build/parent-child-composition/) — la paire children et member_of.
