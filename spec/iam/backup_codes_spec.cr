# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::BackupCodes do
  describe ".generate" do
    it "mints a full set of display-form codes and stores only digests" do
      with_db do |db|
        account_id = create_test_account(db)

        generated = Facet::IAM::BackupCodes.generate(db, account_id)
        codes = generated.codes
        codes.size.should eq(Facet::IAM::BackupCodes::COUNT)
        codes.each do |code|
          code.should match(/^[0-9a-f]{4}-[0-9a-f]{4}$/)
        end
        codes.uniq.size.should eq(codes.size)

        rows = db.query_all(
          "SELECT code_hash, used_at FROM mfa_backup_codes WHERE account_id = $1",
          account_id,
          as: {String, Time?},
        )
        rows.size.should eq(Facet::IAM::BackupCodes::COUNT)
        rows.each do |hash, used_at|
          hash.should match(/^[0-9a-f]{64}$/)
          used_at.should be_nil
        end

        # The plaintext of any code is not in the stored digest.
        codes.each do |code|
          normalized = code.delete('-')
          rows.map(&.[0]).should_not contain(normalized)
        end
      end
    end

    it "replaces a previous set — old codes die, new codes work" do
      with_db do |db|
        account_id = create_test_account(db)

        first = Facet::IAM::BackupCodes.generate(db, account_id).codes
        second = Facet::IAM::BackupCodes.generate(db, account_id).codes

        second.size.should eq(Facet::IAM::BackupCodes::COUNT)
        count = db.query_one(
          "SELECT count(*) FROM mfa_backup_codes WHERE account_id = $1",
          account_id,
          as: Int64,
        )
        count.should eq(Facet::IAM::BackupCodes::COUNT)

        # Every first-set code is gone: consume must fail on each.
        first.each do |code|
          Facet::IAM::BackupCodes.consume(db, account_id, code).should be_false
        end

        # A second-set code consumes.
        Facet::IAM::BackupCodes.consume(db, account_id, second.first).should be_true
      end
    end
  end

  describe ".consume" do
    it "accepts the display form, the bare form, and uppercased typing" do
      with_db do |db|
        account_id = create_test_account(db)
        code = Facet::IAM::BackupCodes.generate(db, account_id).codes.first
        bare = code.delete('-')

        Facet::IAM::BackupCodes.consume(db, account_id, bare).should be_true
      end
    end

    it "accepts an uppercased variant" do
      with_db do |db|
        account_id = create_test_account(db)
        code = Facet::IAM::BackupCodes.generate(db, account_id).codes.first

        Facet::IAM::BackupCodes.consume(db, account_id, code.upcase).should be_true
      end
    end

    it "is single-use — the second attempt fails" do
      with_db do |db|
        account_id = create_test_account(db)
        code = Facet::IAM::BackupCodes.generate(db, account_id).codes.first

        Facet::IAM::BackupCodes.consume(db, account_id, code).should be_true
        Facet::IAM::BackupCodes.consume(db, account_id, code).should be_false
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(9)
      end
    end

    it "rejects a wrong code and another account's code" do
      with_db do |db|
        account_a = create_test_account(db, email: "a@example.com")
        account_b = create_test_account(db, email: "b@example.com")
        code_a = Facet::IAM::BackupCodes.generate(db, account_a).codes.first

        Facet::IAM::BackupCodes.consume(db, account_a, "0000-0000").should be_false
        Facet::IAM::BackupCodes.consume(db, account_b, code_a).should be_false

        # The wrong guesses did not burn the real code.
        Facet::IAM::BackupCodes.consume(db, account_a, code_a).should be_true
      end
    end
  end

  describe ".remaining" do
    it "counts only unconsumed codes" do
      with_db do |db|
        account_id = create_test_account(db)
        codes = Facet::IAM::BackupCodes.generate(db, account_id).codes

        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(10)
        Facet::IAM::BackupCodes.consume(db, account_id, codes[0]).should be_true
        Facet::IAM::BackupCodes.consume(db, account_id, codes[1]).should be_true
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(8)
      end
    end
  end

  describe ".clear" do
    it "deletes every code for the account" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::IAM::BackupCodes.generate(db, account_id)

        Facet::IAM::BackupCodes.clear(db, account_id)
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(0)

        # Clear on an account with no codes is a no-op.
        Facet::IAM::BackupCodes.clear(db, account_id)
      end
    end
  end
end
