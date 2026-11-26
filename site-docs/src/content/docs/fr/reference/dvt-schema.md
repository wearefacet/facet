---
title: Schéma du modèle DVT
description: "Le schéma JSON d’un modèle DocumentView : types de nœuds, clés du modèle et règles de validation."
audience: [author, developer]
features: [DOM-22]
type: reference
sidebar:
  order: 11
verified_at: 008dd880
---

> Généré depuis `src/doctype/view_template_validator.cr` par `make gen-docs-dvt-schema`. Ne modifiez pas ce fichier à la main.

Cette page sert à vérifier les clés et les types de nœuds qu’accepte un modèle de vue.

Un modèle DocumentView (DVT) est un arbre JSON stocké sur le champ `template` d’un document `core.DocumentView`. Le validateur sous `src/doctype/` parcourt l’arbre au moment de l’écriture. Il signale une propriété obligatoire manquante ou une forme incorrecte comme une erreur, et un nœud qui s’afficherait mais se dégraderait comme un avertissement.

## Types de nœuds

Chaque nœud est un objet avec un discriminant `type`. Un type de nœud que le validateur ne connaît pas produit un avertissement ; le frontend n’affiche rien pour lui.

| Type de nœud | Famille | Propriétés obligatoires |
| --- | --- | --- |
| `array` | container | `children`, `field` |
| `capsule` | display | `value` |
| `col` | container | `children` |
| `dict` | container | `children`, `field` |
| `email` | display | `href`, `label` |
| `field` | display | `value` |
| `grid` | container | `children`, `layout` |
| `header` | display | — |
| `hr` | display | — |
| `if` | container | `children`, `field` |
| `image` | display | `src` |
| `image-artifact` | display | `field` |
| `input` | input | `field` |
| `input-color` | input | `field`, `label` |
| `input-date` | input | `field`, `label` |
| `input-dateperiod` | input | `field`, `label` |
| `input-datetime` | input | `field`, `label` |
| `input-file` | input | `field`, `label` |
| `input-list` | input | `field`, `label` |
| `input-longtext` | input | `field`, `label` |
| `input-money` | input | `field`, `label` |
| `input-period` | input | `field`, `label` |
| `input-reference` | input | `field`, `label` |
| `input-secret` | input | `field`, `label` |
| `input-select` | input | `field`, `label`, `options` |
| `input-text` | input | `field`, `label` |
| `input-toggle` | input | `field`, `label` |
| `label` | display | `value` |
| `link` | display | `href`, `label` |
| `markdown` | display | `field` |
| `object` | container | `children`, `field` |
| `record-meta` | display | — |
| `relation` | display | `doctype`, `label`, `source` |
| `row` | container | `children`, `layout` |
| `section` | container | `children`, `label` |
| `sidebar` | container | `children` |
| `tabs` | container | `tabs` |
| `title` | display | `value` |

## Clés du modèle

| Clé | Type | Obligatoire sur | Rôle |
| --- | --- | --- | --- |
| `type` | string | every node | Node discriminator. The frontend dispatches on it. |
| `field` | string | object, if, array, dict, image-artifact, markdown, input, input-* | The bound field. Inputs write it; wrappers scope their children to it. |
| `children` | array of nodes | containers | Child nodes. The validator recurses through it. |
| `else` | array of nodes | — (optional on if) | The branch an if node renders when the condition is false. |
| `tabs` | array of tab entries | tabs | Tab descriptors: objects with a label and children. |
| `label` | string | input-* (not input), relation, section | Visible text of the control, relation, or section. |
| `value` | string | label, field, title, capsule | The literal text or bound value the node renders. |
| `layout` | string | grid, row | Layout instruction. On an array node the optional value is inline or stack. |
| `src` | string | image | Image URL. Carries $field interpolation. |
| `href` | string | link, email | Link target. Carries $field interpolation. |
| `options` | array of {value, label} | input-select | The closed choice set of the select. |
| `source` | object | relation | Query mode of the relation: kind children with rel, or kind filter with field. |
| `doctype` | string | relation | Qualified target doctype of the relation. |
| `view` | string | — (optional on relation) | Relation rendering: capsule, inline, table. The frontend falls back to capsule. |
| `editable` | boolean | — (optional on relation and columns) | Inline editing toggle. Only a children source may carry it. |
| `columns` | array of {key, editable?} | — (optional on relation) | Table columns for the relation. Each column needs a non-empty key. |

## Schéma JSON

Le schéma exprime le contrat structurel que le validateur applique : le discriminant, les propriétés obligatoires par type avec leurs formes, et les entrées de relation, d’onglet, d’option et de colonne. Le schéma reste aussi strict que le validateur — rien de plus, rien de moins.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Facet DocumentView template (DVT)",
  "$ref": "#/$defs/node",
  "$defs": {
    "node": {
      "type": "object",
      "required": [
        "type"
      ],
      "properties": {
        "type": {
          "type": "string",
          "minLength": 1
        },
        "field": {
          "type": "string"
        },
        "children": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/node"
          }
        },
        "else": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/node"
          }
        },
        "tabs": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/tab"
          }
        },
        "label": {
          "type": "string"
        },
        "value": {
          "type": "string"
        },
        "layout": {
          "type": "string"
        },
        "src": {
          "type": "string"
        },
        "href": {
          "type": "string"
        },
        "options": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/option"
          }
        },
        "source": {
          "$ref": "#/$defs/relationSource"
        },
        "doctype": {
          "type": "string"
        },
        "view": {
          "enum": [
            "capsule",
            "inline",
            "table"
          ]
        },
        "editable": {
          "type": "boolean"
        },
        "columns": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/relationColumn"
          }
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "type": {
                "const": "array"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "children"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              },
              "layout": {
                "enum": [
                  "inline",
                  "stack"
                ]
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "capsule"
              }
            }
          },
          "then": {
            "required": [
              "value"
            ],
            "properties": {
              "value": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "col"
              }
            }
          },
          "then": {
            "required": [
              "children"
            ],
            "properties": {
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "dict"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "children"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "email"
              }
            }
          },
          "then": {
            "required": [
              "href",
              "label"
            ],
            "properties": {
              "href": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "field"
              }
            }
          },
          "then": {
            "required": [
              "value"
            ],
            "properties": {
              "value": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "grid"
              }
            }
          },
          "then": {
            "required": [
              "layout",
              "children"
            ],
            "properties": {
              "layout": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "header"
              }
            }
          },
          "then": {
            "required": [],
            "properties": {}
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "hr"
              }
            }
          },
          "then": {
            "required": [],
            "properties": {}
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "if"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "children"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "image"
              }
            }
          },
          "then": {
            "required": [
              "src"
            ],
            "properties": {
              "src": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "image-artifact"
              }
            }
          },
          "then": {
            "required": [
              "field"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input"
              }
            }
          },
          "then": {
            "required": [
              "field"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-color"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-date"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-dateperiod"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-datetime"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-file"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-list"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-longtext"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-money"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-period"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-reference"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-secret"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-select"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label",
              "options"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              },
              "options": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-text"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "input-toggle"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "label"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "label"
              }
            }
          },
          "then": {
            "required": [
              "value"
            ],
            "properties": {
              "value": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "link"
              }
            }
          },
          "then": {
            "required": [
              "href",
              "label"
            ],
            "properties": {
              "href": {
                "type": "string",
                "minLength": 1
              },
              "label": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "markdown"
              }
            }
          },
          "then": {
            "required": [
              "field"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "object"
              }
            }
          },
          "then": {
            "required": [
              "field",
              "children"
            ],
            "properties": {
              "field": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "record-meta"
              }
            }
          },
          "then": {
            "required": [],
            "properties": {}
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "relation"
              }
            }
          },
          "then": {
            "required": [
              "label",
              "doctype",
              "source"
            ],
            "properties": {
              "label": {
                "type": "string",
                "minLength": 1
              },
              "doctype": {
                "type": "string",
                "minLength": 1
              },
              "source": {
                "type": "object"
              },
              "view": {
                "enum": [
                  "capsule",
                  "inline",
                  "table"
                ]
              },
              "editable": {
                "type": "boolean"
              },
              "columns": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "row"
              }
            }
          },
          "then": {
            "required": [
              "layout",
              "children"
            ],
            "properties": {
              "layout": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "section"
              }
            }
          },
          "then": {
            "required": [
              "label",
              "children"
            ],
            "properties": {
              "label": {
                "type": "string",
                "minLength": 1
              },
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "sidebar"
              }
            }
          },
          "then": {
            "required": [
              "children"
            ],
            "properties": {
              "children": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "tabs"
              }
            }
          },
          "then": {
            "required": [
              "tabs"
            ],
            "properties": {
              "tabs": {
                "type": "array"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "title"
              }
            }
          },
          "then": {
            "required": [
              "value"
            ],
            "properties": {
              "value": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        }
      ]
    },
    "tab": {
      "type": "object",
      "required": [
        "label",
        "children"
      ],
      "properties": {
        "label": {
          "type": "string",
          "minLength": 1
        },
        "children": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/node"
          }
        }
      }
    },
    "option": {
      "type": "object",
      "required": [
        "value",
        "label"
      ],
      "properties": {
        "value": {
          "type": "string",
          "minLength": 1
        },
        "label": {
          "type": "string",
          "minLength": 1
        }
      }
    },
    "relationSource": {
      "type": "object",
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "enum": [
            "children",
            "filter"
          ]
        },
        "rel": {
          "type": "string"
        },
        "field": {
          "type": "string"
        }
      }
    },
    "relationColumn": {
      "type": "object",
      "required": [
        "key"
      ],
      "properties": {
        "key": {
          "type": "string",
          "minLength": 1
        },
        "editable": {
          "type": "boolean"
        }
      }
    }
  }
}
```

## Affinité entre nœuds d’entrée et types de champs

Chaque nœud d’entrée spécialisé accepte un ensemble de types de champs. Une liaison hors de cet ensemble produit un avertissement : le contrôle s’affiche, mais la valeur peut échouer à la validation à l’enregistrement. Le nœud `input` automatique rend le contrôle préféré pour le type du champ lié.

| Nœud d’entrée | Types de champs acceptés |
| --- | --- |
| `input-color` | `color` |
| `input-date` | `date` |
| `input-dateperiod` | `dateperiod` |
| `input-datetime` | `datetime` |
| `input-file` | `file` |
| `input-list` | `array` |
| `input-longtext` | `longtext` |
| `input-money` | `money` |
| `input-period` | `period` |
| `input-reference` | `reference` |
| `input-secret` | `secret` |
| `input-select` | `enum` |
| `input-text` | `any`, `date`, `duration`, `enum`, `integer`, `phone`, `string`, `url` |
| `input-toggle` | `boolean` |

## Règles que le schéma ne peut pas exprimer

| Règle | Ce que le validateur applique |
| --- | --- |
| Missing type discriminator | A node without a non-empty type is an error. The message lists the keys the node carries. |
| Unknown node type | A type outside the node table draws a warning; the frontend renders nothing for it. |
| Required property shapes | children, tabs, and options must be arrays. source must be an object. Every other required property must be a non-empty string. |
| Dotted input bindings | An input or input-* node bound to a dotted path is an error. Wrap the top-level field in an object node and bind the bare sub-field name. |
| Unknown binding target | An input bound to a field that does not exist at the current scope is an error. |
| Container and computed bindings | A scalar input cannot bind an array, object, dictionary, or data field, or a field with no type definition. input-list is the one array editor. |
| read_only bindings | An input bound to a read_only field draws a warning: the value can never be saved. |
| input-list item types | input-list warns when its items are not color, phone, string, url. A target that is not an array field warns too. |
| File tokens in URLs | A link, email, or image node that interpolates a $token resolving to a file field draws a warning: show files with a field row and pictures with image-artifact. |
| Wrapper targets | object and dict need an object or dictionary target; array needs an array target. A mismatching shape warns. An if node accepts any field type. |
| Relation source kinds | source.kind must be children (with rel) or filter (with field). Anything else is an error. |
| Relation editability | editable: true on a filter-bound relation is an error: the parent does not own those rows. |
| Relation columns | A column must be an object with a non-empty key. editable on a dotted column key warns: the toggle writes the row document's own fields only. |
| Select options | An empty options array warns. An option entry that is not an object, or misses a value or label string, is an error. |
| Tab entries | A tabs entry must be an object with a label and children. |
| Container field types | The validator treats array, data, dictionary, object as container types for binding checks. |

## Voir aussi

- [Modèles de vue](/fr/build/view-templates/) — comment écrire l’arbre que ce schéma décrit.
