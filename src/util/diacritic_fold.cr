# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Accent-insensitive folding for both sides of the trigram search:
    # the `search` corpus at write time (`Document::Search`) and the query
    # term at read time (`Document::FilterCompiler`). One fold function on
    # both sides gives one contract — a term without diacritics matches an
    # accented corpus, and any accented term matches a folded corpus.
    #
    # The transform is: case fold (`ß`→`ss`), compatibility-decompose
    # (NFKD: `é`→`e` + U+0301, `ﬁ`→`fi`, fullwidth `Ａ`→`A`), strip
    # combining diacritic marks, then recompose (NFC, e.g. Hangul jamo
    # back into syllables).
    #
    # The PostgreSQL `unaccent` extension was rejected for this: an
    # expression index would need an IMMUTABLE wrapper, trigger-time
    # folding breaks the "trigger stays dumb" rule, and two fold
    # mechanisms (PG + Crystal) could drift.
    module DiacriticFold
      # Letters that are distinct code points, not base + combining mark,
      # so NFKD leaves them alone. Lowercase only, because we case-fold first.
      EXTRA = {
        'æ' => "ae", 'œ' => "oe", 'ø' => "o", 'đ' => "d", 'ð' => "d",
        'ł' => "l", 'þ' => "th", 'ı' => "i", 'ħ' => "h", 'ŧ' => "t",
        'ŀ' => "l", 'ĸ' => "k",
      }

      # Only strip marks in the diacritic blocks (Latin/Greek/Cyrillic, etc.).
      # Blindly dropping every mark would break Thai, Devanagari, and other
      # scripts, where vowel signs are marks.
      DIACRITIC_RANGES = {
        0x0300..0x036F, # Combining Diacritical Marks
        0x1AB0..0x1AFF, # ... Extended
        0x1DC0..0x1DFF, # ... Supplement
        0x20D0..0x20FF, # ... for Symbols
        0xFE20..0xFE2F, # Combining Half Marks
      }

      def self.strip?(c : Char) : Bool
        return false unless c.mark?
        DIACRITIC_RANGES.any?(&.includes?(c.ord))
      end

      # Note the fold merges some distinct Cyrillic letters (`й`→`и`,
      # `ї`→`і`) while folding `ё`→`е` — accepted: one broad rule gives a
      # forgiving search; script detection would need more code.
      def self.fold(s : String) : String
        # Case fold first (ß -> ss, ẞ -> ss), then compatibility-decompose
        # (ﬁ -> fi, fullwidth Ａ -> A, é -> e + U+0301).
        d = s.downcase(Unicode::CaseOptions::Fold).unicode_normalize(:nfkd)

        folded = String.build(d.bytesize) do |io|
          d.each_char do |c|
            next if strip?(c)
            if r = EXTRA[c]?
              io << r
            else
              io << c
            end
          end
        end

        # Recompose anything left (e.g. Hangul jamo back into syllables).
        folded.unicode_normalize(:nfc)
      end
    end
  end
end
