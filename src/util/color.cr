# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Color parsing and normalization utilities.
    #
    # Accepts CSS color formats (hex, rgb, rgba, hsl, hsla) and normalizes
    # them to 32-bit hexadecimal `#RRGGBBAA`. Alpha defaults to `FF` when
    # not provided.
    #
    # ```
    # Facet::Util::Color.normalize("#ABC")              # => "#aabbccff"
    # Facet::Util::Color.normalize("rgb(255,0,0)")      # => "#ff0000ff"
    # Facet::Util::Color.normalize("hsl(300,100%,50%)") # => "#ff00ffff"
    # ```
    module Color
      HEX_RE      = /^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/
      RGB_FUNC_RE = /^rgba?\s*\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([0-9.]+%?))?\s*\)$/
      HSL_FUNC_RE = /^hsla?\s*\(\s*(\d{1,3}(?:\.\d+)?)\s*,\s*(\d{1,3}(?:\.\d+)?)%\s*,\s*(\d{1,3}(?:\.\d+)?)%(?:\s*,\s*([0-9.]+%?))?\s*\)$/

      # Normalizes a color string to `#RRGGBBAA` format.
      # Raises `ArgumentError` if the string cannot be parsed.
      def self.normalize(input : String) : String
        stripped = input.strip

        case stripped
        when HEX_RE
          normalize_hex(stripped)
        when RGB_FUNC_RE
          normalize_rgb($1.to_i, $2.to_i, $3.to_i, $4?)
        when HSL_FUNC_RE
          normalize_hsl($1.to_f, $2.to_f, $3.to_f, $4?)
        else
          raise ArgumentError.new("Invalid color format: #{input.inspect}")
        end
      end

      # Returns `true` if the string is a valid color value.
      def self.valid?(input : String) : Bool
        normalize(input)
        true
      rescue ArgumentError
        false
      end

      private def self.normalize_hex(hex : String) : String
        h = hex.lchop('#')

        case h.size
        when 3
          # #RGB → #RRGGBBFF
          r = h[0].to_i(16) * 17
          g = h[1].to_i(16) * 17
          b = h[2].to_i(16) * 17
          hex_format(r, g, b, 255)
        when 4
          # #RGBA → #RRGGBBAA
          r = h[0].to_i(16) * 17
          g = h[1].to_i(16) * 17
          b = h[2].to_i(16) * 17
          a = h[3].to_i(16) * 17
          hex_format(r, g, b, a)
        when 6
          # #RRGGBB → #RRGGBBFF
          hex_format(h[0..1].to_i(16), h[2..3].to_i(16), h[4..5].to_i(16), 255)
        when 8
          # #RRGGBBAA
          hex_format(h[0..1].to_i(16), h[2..3].to_i(16), h[4..5].to_i(16), h[6..7].to_i(16))
        else
          raise ArgumentError.new("Unexpected hex length: #{hex.inspect}")
        end
      end

      private def self.normalize_rgb(r : Int32, g : Int32, b : Int32, alpha : String?) : String
        unless (0..255).covers?(r) && (0..255).covers?(g) && (0..255).covers?(b)
          raise ArgumentError.new("RGB values must be in range 0–255")
        end

        a = parse_alpha(alpha)
        hex_format(r, g, b, a)
      end

      private def self.normalize_hsl(h : Float64, s : Float64, l : Float64, alpha : String?) : String
        unless (0..360).covers?(h) && (0..100).covers?(s) && (0..100).covers?(l)
          raise ArgumentError.new("HSL values out of range: h=#{h}, s=#{s}%, l=#{l}%")
        end

        r, g, b = hsl_to_rgb(h / 360.0, s / 100.0, l / 100.0)
        a = parse_alpha(alpha)
        hex_format(r, g, b, a)
      end

      # Converts HSL to RGB. All values are normalized to [0.0, 1.0].
      private def self.hsl_to_rgb(h : Float64, s : Float64, l : Float64) : Tuple(Int32, Int32, Int32)
        if s == 0.0
          gray = (l * 255).round.to_i
          return {gray, gray, gray}
        end

        hue_to_rgb = ->(p : Float64, q : Float64, t : Float64) {
          t = t + 1.0 if t < 0.0
          t = t - 1.0 if t > 1.0
          case t
          when 0.0...1.0/6.0 then p + (q - p) * 6.0 * t
          when 1.0/6.0...0.5 then q
          when 0.5...2.0/3.0 then p + (q - p) * (2.0/3.0 - t) * 6.0
          else                    p
          end
        }

        q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        p = 2.0 * l - q

        r = (hue_to_rgb.call(p, q, h + 1.0/3.0) * 255).round.to_i.clamp(0, 255)
        g = (hue_to_rgb.call(p, q, h) * 255).round.to_i.clamp(0, 255)
        b = (hue_to_rgb.call(p, q, h - 1.0/3.0) * 255).round.to_i.clamp(0, 255)

        {r, g, b}
      end

      # Parses an optional alpha string into a 0–255 integer.
      #
      # Per CSS spec, functional notations (`rgba`, `hsla`) use alpha in the
      # range 0.0–1.0. This method always treats the input as such (unless
      # it ends with '%' for percentage notation).
      # Returns 255 when nil (alpha not provided).
      private def self.parse_alpha(alpha : String?) : Int32
        return 255 if alpha.nil?

        a_str = alpha.strip

        # Percentage format (e.g. "50%")
        if a_str.ends_with?('%')
          pct = a_str.rchop('%').to_f
          unless (0.0..100.0).covers?(pct)
            raise ArgumentError.new("Alpha percentage must be in range 0–100")
          end
          return (pct / 100.0 * 255.0).round.to_i.clamp(0, 255)
        end

        a_float = a_str.to_f
        unless (0.0..1.0).covers?(a_float)
          raise ArgumentError.new("Alpha must be in range 0.0–1.0 (got: #{a_str})")
        end

        (a_float * 255.0).round.to_i.clamp(0, 255)
      end

      # Formats RGBA components to `#RRGGBBAA`.
      private def self.hex_format(r : Int32, g : Int32, b : Int32, a : Int32) : String
        r = r.clamp(0, 255)
        g = g.clamp(0, 255)
        b = b.clamp(0, 255)
        a = a.clamp(0, 255)

        String.build do |io|
          io << '#'
          io << r.to_s(16, upcase: false).rjust(2, '0')
          io << g.to_s(16, upcase: false).rjust(2, '0')
          io << b.to_s(16, upcase: false).rjust(2, '0')
          io << a.to_s(16, upcase: false).rjust(2, '0')
        end
      end

      # ── Hash color (deterministic string → hex) ──────────────────────────

      # Returns a stable `#RRGGBB` hex color derived from a string seed.
      #
      # Uses the same algorithm as the frontend `hashColor`:
      # FNV-1a 32-bit → OKLCH(L=0.58, C=0.11, H=hash%360) → #RRGGBB.
      # The result is readable on both light and dark backgrounds.
      def self.hash_color(seed : String) : String
        # FNV-1a 32-bit (wrapping arithmetic)
        h = 0x811c9dc5u32
        seed.each_byte do |b|
          h ^= b
          h &*= 0x01000193u32
        end
        hue = h.to_f % 360.0

        # OKLCH → linear sRGB → gamma sRGB → #RRGGBB
        to_hex_from_oklch(0.58, 0.11, hue)
      end

      # Converts OKLCH(L, C, H) to `#RRGGBB` hex string.
      private def self.to_hex_from_oklch(l : Float64, c : Float64, h : Float64) : String
        h_rad = h * Math::PI / 180.0
        a = c * Math.cos(h_rad)
        b = c * Math.sin(h_rad)

        # OKLab → linear sRGB
        l_ = l + 0.396_337_777_4 * a + 0.215_803_757_3 * b
        m_ = l - 0.105_561_345_8 * a - 0.063_854_172_8 * b
        s_ = l - 0.089_484_177_5 * a - 1.291_485_548 * b

        l3 = l_ ** 3
        m3 = m_ ** 3
        s3 = s_ ** 3

        r_lin = 4.076_741_662_1 * l3 - 3.307_711_591_3 * m3 + 0.230_969_929_2 * s3
        g_lin = -1.268_438_004_6 * l3 + 2.609_757_401_1 * m3 - 0.341_319_396_5 * s3
        b_lin = -0.004_196_086_3 * l3 - 0.703_418_614_7 * m3 + 1.707_614_701 * s3

        # Gamma sRGB
        g2s = ->(x : Float64) { x <= 0.003_130_8 ? 12.92 * x : 1.055 * x ** (1.0 / 2.4) - 0.055 }

        r = (g2s.call(r_lin.clamp(0.0, 1.0)) * 255.0).round.to_i.clamp(0, 255)
        g = (g2s.call(g_lin.clamp(0.0, 1.0)) * 255.0).round.to_i.clamp(0, 255)
        b = (g2s.call(b_lin.clamp(0.0, 1.0)) * 255.0).round.to_i.clamp(0, 255)

        String.build do |io|
          io << '#'
          io << r.to_s(16, upcase: false).rjust(2, '0')
          io << g.to_s(16, upcase: false).rjust(2, '0')
          io << b.to_s(16, upcase: false).rjust(2, '0')
        end
      end
    end
  end
end
