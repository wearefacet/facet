# Util::Color — CSS Color Parsing and Normalization

**Files:** `src/util/color.cr`

The `Facet::Util::Color` module parses CSS color strings and normalizes them to 32-bit lowercase hex `#RRGGBBAA`. Alpha defaults to `FF` when not provided.

## Accepted input formats

| Format | Example | Normalized |
|---|---|---|
| Hex 3 | `#ABC` | `#aabbccff` |
| Hex 4 | `#F0A8` | `#ff00aa88` |
| Hex 6 | `#FF00CC` | `#ff00ccff` |
| Hex 8 | `#FF00CC80` | `#ff00cc80` |
| `rgb` | `rgb(255, 0, 204)` | `#ff00ccff` |
| `rgba` | `rgba(255, 0, 0, 0.5)` | `#ff000080` |
| `hsl` | `hsl(300, 100%, 50%)` | `#ff00ffff` |
| `hsla` | `hsla(300, 100%, 50%, 0.5)` | `#ff00ff80` |

Alpha accepts both 0.0–1.0 float and percentage notation (`50%`).

## Public API

| Method | Returns | Description |
|---|---|---|
| `.normalize(input)` | `String` | Parses and normalizes to `#RRGGBBAA`. Raises `ArgumentError` on invalid input. |
| `.valid?(input)` | `Bool` | Returns `true` if the string is a valid color value. |

## Usage

```crystal
require "./util/color"

Facet::Util::Color.normalize("#ABC")          # => "#aabbccff"
Facet::Util::Color.normalize("rgb(255, 0, 0)") # => "#ff0000ff"
Facet::Util::Color.normalize("hsl(300, 100%, 50%)") # => "#ff00ffff"
Facet::Util::Color.valid?("#GGG")              # => false
```

## Edge cases

- **Shorthand hex** (`#RGB`) doubles each nibble: `#F0A` → `#FF00AAFF`
- **No alpha** → defaults to `FF` (fully opaque)
- **Out-of-range** values (RGB > 255, HSL hue > 360, alpha > 1.0) → `ArgumentError`
- **Leading/trailing whitespace** is stripped before parsing