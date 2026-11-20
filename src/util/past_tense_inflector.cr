# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Inflects verbs to past tense (past participle) for event naming.
    #
    # Handles regular verbs, monosyllabic CVC doubling, polysyllabic
    # stressed‑final‑syllable doubling, and a comprehensive irregular verb
    # table with prefix stripping ("rebuild" → "rebuilt").
    #
    # Also provides `pluralize` and `singularize` for basic English
    # noun inflection.
    #
    # ```
    # inflector = Facet::Util::PastTenseInflector.new
    # inflector.inflect_past("create_object") # => "object_created"
    # inflector.inflect_past("write")         # => "written"
    # inflector.pluralize("city")             # => "cities"
    # ```
    class PastTenseInflector
      # Irregular verbs mapped to their past participle form.
      # https://www.grammar.cl/Past/Irregular_Verbs_List.htm
      PAST_TENSE_EXCEPTIONS = {
        "arise"      => "arisen",
        "babysit"    => "babysat",
        "be"         => "been",
        "bear"       => "borne",
        "beat"       => "beaten",
        "become"     => "become",
        "bend"       => "bent",
        "begin"      => "begun",
        "bet"        => "bet",
        "bind"       => "bound",
        "bite"       => "bitten",
        "bleed"      => "bled",
        "blow"       => "blown",
        "break"      => "broken",
        "breed"      => "bred",
        "bring"      => "brought",
        "broadcast"  => "broadcast",
        "build"      => "built",
        "burst"      => "burst",
        "buy"        => "bought",
        "cast"       => "cast",
        "catch"      => "caught",
        "choose"     => "chosen",
        "cling"      => "clung",
        "come"       => "come",
        "cost"       => "cost",
        "creep"      => "crept",
        "cut"        => "cut",
        "deal"       => "dealt",
        "dig"        => "dug",
        "do"         => "done",
        "draw"       => "drawn",
        "drink"      => "drunk",
        "drive"      => "driven",
        "eat"        => "eaten",
        "fall"       => "fallen",
        "feed"       => "fed",
        "feel"       => "felt",
        "fight"      => "fought",
        "find"       => "found",
        "flee"       => "fled",
        "fling"      => "flung",
        "fly"        => "flown",
        "forbid"     => "forbidden",
        "forget"     => "forgotten",
        "forgive"    => "forgiven",
        "freeze"     => "frozen",
        "get"        => "gotten",
        "give"       => "given",
        "go"         => "gone",
        "grind"      => "ground",
        "grow"       => "grown",
        "hang"       => "hung",
        "have"       => "had",
        "hear"       => "heard",
        "hide"       => "hidden",
        "hit"        => "hit",
        "hold"       => "held",
        "hurt"       => "hurt",
        "keep"       => "kept",
        "kneel"      => "knelt",
        "know"       => "known",
        "lay"        => "laid",
        "lead"       => "led",
        "leave"      => "left",
        "lend"       => "lent",
        "let"        => "let",
        "lie"        => "lain",
        "light"      => "lit",
        "lose"       => "lost",
        "make"       => "made",
        "mean"       => "meant",
        "meet"       => "met",
        "pay"        => "paid",
        "put"        => "put",
        "quit"       => "quit",
        "read"       => "read",
        "ride"       => "ridden",
        "ring"       => "rung",
        "rise"       => "risen",
        "run"        => "run",
        "saw"        => "sawn",
        "say"        => "said",
        "see"        => "seen",
        "seek"       => "sought",
        "sell"       => "sold",
        "send"       => "sent",
        "set"        => "set",
        "sew"        => "sewn",
        "shake"      => "shaken",
        "shed"       => "shed",
        "shine"      => "shone",
        "shoot"      => "shot",
        "show"       => "shown",
        "shrink"     => "shrunk",
        "shut"       => "shut",
        "sing"       => "sung",
        "sink"       => "sunk",
        "sit"        => "sat",
        "slay"       => "slain",
        "sleep"      => "slept",
        "slide"      => "slid",
        "sling"      => "slung",
        "speak"      => "spoken",
        "speed"      => "sped",
        "spend"      => "spent",
        "spin"       => "spun",
        "spit"       => "spat",
        "split"      => "split",
        "spread"     => "spread",
        "spring"     => "sprung",
        "stand"      => "stood",
        "steal"      => "stolen",
        "stick"      => "stuck",
        "sting"      => "stung",
        "stride"     => "stridden",
        "strike"     => "struck",
        "strive"     => "striven",
        "swear"      => "sworn",
        "sweep"      => "swept",
        "swim"       => "swum",
        "swing"      => "swung",
        "take"       => "taken",
        "teach"      => "taught",
        "tear"       => "torn",
        "tell"       => "told",
        "think"      => "thought",
        "throw"      => "thrown",
        "tread"      => "trodden",
        "understand" => "understood",
        "wake"       => "woken",
        "wear"       => "worn",
        "weave"      => "woven",
        "weep"       => "wept",
        "win"        => "won",
        "wind"       => "wound",
        "withdraw"   => "withdrawn",
        "wring"      => "wrung",
        "write"      => "written",
      }

      # Prefixes that can be stripped to retry the irregular lookup,
      # e.g. "rebuild" => "re" + built, "undergo" => "under" + gone.
      VERB_PREFIXES = /\A(under|inter|over|with|fore|out|mis|re|un)(?=.{2,})/

      # Polysyllabic verbs with final‑syllable stress that double the final
      # consonant ("occur" → "occurred"), unlike "visit", "open", etc.
      FINAL_STRESS_DOUBLING = {
        "admit"    => "admitted",
        "allot"    => "allotted",
        "commit"   => "committed",
        "compel"   => "compelled",
        "concur"   => "concurred",
        "confer"   => "conferred",
        "control"  => "controlled",
        "defer"    => "deferred",
        "deter"    => "deterred",
        "emit"     => "emitted",
        "equip"    => "equipped",
        "excel"    => "excelled",
        "expel"    => "expelled",
        "impel"    => "impelled",
        "incur"    => "incurred",
        "infer"    => "inferred",
        "occur"    => "occurred",
        "omit"     => "omitted",
        "patrol"   => "patrolled",
        "permit"   => "permitted",
        "prefer"   => "preferred",
        "propel"   => "propelled",
        "rebel"    => "rebelled",
        "recur"    => "recurred",
        "refer"    => "referred",
        "regret"   => "regretted",
        "remit"    => "remitted",
        "repel"    => "repelled",
        "submit"   => "submitted",
        "transfer" => "transferred",
        "transmit" => "transmitted",
      }

      PLURAL_EXCEPTIONS = {
        "child"  => "children",
        "person" => "people",
        "man"    => "men",
        "woman"  => "women",
      }

      PLURAL_RULES = [
        {/^(.*)us$/, "\\1i"},
        {/^(.*)is$/, "\\1es"},
        {/^(.*[aeiou])y$/, "\\1ys"},
        {/^(.*)y$/, "\\1ies"},
        {/^(.*)o$/, "\\1oes"},
        {/^(.*)s$/, "\\1s"},
      ]

      SINGULAR_RULES = [
        {/^(.*)i$/, "\\1us"},
        {/^(.*)ies$/, "\\1y"},
        {/^(.*)oes$/, "\\1o"},
        {/^(.*)es$/, "\\1is"},
        {/^(.*)s$/, "\\1"},
      ]

      # Creates a new inflector.
      #
      # Accepts optional `verb_exceptions` and `plural_exceptions` hashes to
      # override the built‑in exception tables.
      def initialize(
        @verb_exceptions : Hash(String, String) = PAST_TENSE_EXCEPTIONS,
        @plural_exceptions : Hash(String, String) = PLURAL_EXCEPTIONS,
      )
        @singular_exceptions = @plural_exceptions.each_with_object({} of String => String) { |(k, v), h| h[v] = k }
      end

      getter verb_exceptions : Hash(String, String)
      getter plural_exceptions : Hash(String, String)
      getter singular_exceptions : Hash(String, String)

      # Inflects a word to its plural form.
      #
      # Returns the word unchanged when `count <= 1`.
      #
      # ```
      # inflector.pluralize("child")   # => "children"
      # inflector.pluralize("city")    # => "cities"
      # inflector.pluralize("user", 1) # => "user"
      # ```
      def pluralize(word : String, count : Int32 = 2) : String
        return word if count <= 1

        @plural_exceptions.fetch(word) do |_key|
          PLURAL_RULES.each do |rule, replacement|
            return word.gsub(rule, replacement) if word =~ rule
          end
          "#{word}s"
        end
      end

      # Inflects a word to its singular form.
      #
      # ```
      # inflector.singularize("children") # => "child"
      # inflector.singularize("cities")   # => "city"
      # ```
      def singularize(word : String) : String
        @singular_exceptions.fetch(word) do |_key|
          SINGULAR_RULES.each do |rule, replacement|
            return word.gsub(rule, replacement) if word =~ rule
          end
          word
        end
      end

      # Inflects a verb to past tense (past participle form).
      #
      # Splits compound inputs on non‑letter characters, inflects the first
      # word, and appends the remaining words after it — ideal for event
      # naming like `object_created`.
      #
      # ```
      # inflector.inflect_past("create_object") # => "object_created"
      # inflector.inflect_past("write")         # => "written"
      # ```
      def inflect_past(verb : String) : String
        words = verb.gsub(/[^a-zA-Z]/, "_").split("_")

        first = words[0]
        past_tense_verb = irregular_past(first) || regular_past(first)

        (words[1..] + [past_tense_verb]).join("_")
      end

      # ------------------------------------------------------------------
      # Private
      # ------------------------------------------------------------------

      private def irregular_past(verb : String) : String?
        @verb_exceptions.fetch(verb, nil) || begin
          if match = verb.match(VERB_PREFIXES)
            if base = @verb_exceptions[match.post_match]?
              "#{match[1]}#{base}"
            end
          end
        end
      end

      private def regular_past(verb : String) : String
        if doubled = FINAL_STRESS_DOUBLING[verb]?
          return doubled
        end

        case verb
        when /e$/
          "#{verb}d"
        when /[^aeiou]y$/
          "#{verb.rchop}ied"
        when /c$/
          "#{verb}ked"
        when /[^aeiouwxy][aeiou][bdglmnprt]$/
          if monosyllabic?(verb)
            "#{verb}#{verb[-1]}ed"
          else
            "#{verb}ed"
          end
        else
          "#{verb}ed"
        end
      end

      private def monosyllabic?(verb : String) : Bool
        verb.scan(/[aeiouy]+/).size == 1
      end
    end
  end
end
