# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/diacritic_fold"

# Matrix for `Util::DiacriticFold` — the fold applied to both sides of the
# trigram search (corpus at write time, term at query time). The expectations
# mirror the validated probe (`tmp/fold_validate.cr`), with the two probe
# expectation errors corrected:
#
# - `"ẞTRAẞE"` carries two capital sharp-s characters, so the fold is
#   `"sstrasse"` (the probe had expected the fold of `"Straße"`).
# - NFKD maps `²` to `2` with no space inserted, so `"10²"` folds to `"102"`.
describe Facet::Util::DiacriticFold do
  describe ".fold" do
    it "folds case and accents together" do
      Facet::Util::DiacriticFold.fold("García").should eq("garcia")
      Facet::Util::DiacriticFold.fold("GARCÍA").should eq("garcia")
      Facet::Util::DiacriticFold.fold("José Müller-Chloé").should eq("jose muller-chloe")
      Facet::Util::DiacriticFold.fold("Straße").should eq("strasse")
      Facet::Util::DiacriticFold.fold("ẞTRAẞE").should eq("sstrasse")
    end

    it "folds NFKD compatibility forms — ligatures, fullwidth, numerals" do
      Facet::Util::DiacriticFold.fold("ﬁnance").should eq("finance")
      Facet::Util::DiacriticFold.fold("ＡＢＣ").should eq("abc")
      Facet::Util::DiacriticFold.fold("Henry Ⅷ").should eq("henry viii")
      Facet::Util::DiacriticFold.fold("10² m").should eq("102 m")
    end

    it "folds Latin letters that are distinct code points" do
      Facet::Util::DiacriticFold.fold("Ærøskøbing").should eq("aeroskobing")
      Facet::Util::DiacriticFold.fold("Łódź").should eq("lodz")
      Facet::Util::DiacriticFold.fold("Đà Nẵng").should eq("da nang")
    end

    it "folds Greek tonos and Cyrillic marks" do
      Facet::Util::DiacriticFold.fold("ένα Ώρα").should eq("ενα ωρα")
      Facet::Util::DiacriticFold.fold("ёж").should eq("еж")
    end

    it "preserves Thai byte-identical — vowel signs are marks outside the diacritic ranges" do
      Facet::Util::DiacriticFold.fold("ภาษาไทย").should eq("ภาษาไทย")
    end

    it "recomposes Korean through the final NFC pass" do
      Facet::Util::DiacriticFold.fold("한국어").should eq("한국어")
    end

    it "is idempotent — corpus folds once at write, term folds once at query" do
      sample = "Crème Brûlée, Straße, Łódź, ﬁnal"
      fold = Facet::Util::DiacriticFold
      fold.fold(fold.fold(sample)).should eq(fold.fold(sample))
    end

    it "leaves LIKE metacharacters untouched — fold runs before LikeEscape.escape" do
      Facet::Util::DiacriticFold.fold("50% oﬀ _\\").should eq("50% off _\\")
    end

    it "is a no-op (modulo case) for ULIDs and plain ASCII" do
      Facet::Util::DiacriticFold.fold("01J8ZQ9K7M4T0000000000000000")
        .should eq("01j8zq9k7m4t0000000000000000")
      Facet::Util::DiacriticFold.fold("plain-ascii-123").should eq("plain-ascii-123")
    end

    it "maps the empty string to the empty string" do
      Facet::Util::DiacriticFold.fold("").should eq("")
    end
  end
end
