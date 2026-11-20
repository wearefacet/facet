# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cli/chain"

# Pure units behind the command-chain pre-validation and the db_reset
# confirmation gate:
#
#   - `Facet::CLI.parse_chain` — validates the whole chain before any
#     command runs and splits it into (command, flags) steps.
#   - `Facet::Migrate::DbResetCLI.parse` — the db_reset flag parser.
#   - `Facet::Migrate.ask` — the pure decision pass of the confirmation
#     gate (`confirm!` turns a refusal into the process exit).
#
# No example here executes a command. The destructive db_reset workflow is
# covered by `spec/migrate/db_reset_spec.cr`, which passes `yes: true`.

# A small stand-in command table — the real one lives in
# `src/cli/commands.cr` and drags the whole application into the compile.
# `parse_chain` takes the tables as arguments, so these specs stay pure.
private def chain_known : Array(String)
  ["server", "migrate", "migrate:down", "db_reset", "seed:dev", "seed:admin"]
end

private def chain_options : Array(String)
  ["migrate:down", "seed:admin"]
end

describe "Facet::CLI.parse_chain" do
  it "splits a chain of bare commands into ordered steps" do
    steps = Facet::CLI.parse_chain(["db_reset", "seed:dev", "server"], chain_known, chain_options)
    steps.map(&.name).should eq(["db_reset", "seed:dev", "server"])
    steps.all?(&.flags.empty?).should be_true
  end

  it "hands dash tokens to the preceding chainable command" do
    steps = Facet::CLI.parse_chain(["db_reset", "--yes", "seed:dev"], chain_known, chain_options)
    steps.map(&.name).should eq(["db_reset", "seed:dev"])
    steps.first.flags.should eq(["--yes"])
    steps.last.flags.should be_empty
  end

  it "rejects an unknown bare token before any command would run" do
    expect_raises(Facet::CLI::ChainError, "Unknown command: boguss") do
      Facet::CLI.parse_chain(["db_reset", "boguss"], chain_known, chain_options)
    end

    # The typo sits after a command that would already have run — the
    # validator must catch it up front.
    expect_raises(Facet::CLI::ChainError, "Unknown command: seed:dv") do
      Facet::CLI.parse_chain(["db_reset", "seed:dev", "seed:dv"], chain_known, chain_options)
    end
  end

  it "leaves an unknown dash token to the command's own parser" do
    steps = Facet::CLI.parse_chain(["db_reset", "--nope", "seed:dev"], chain_known, chain_options)
    steps.map(&.name).should eq(["db_reset", "seed:dev"])
    steps.first.flags.should eq(["--nope"])
  end

  it "folds the rest of the list into an option-taking command" do
    steps = Facet::CLI.parse_chain(["migrate:down", "0008", "--yes"], chain_known, chain_options)
    steps.size.should eq(1)
    steps.first.name.should eq("migrate:down")
    steps.first.flags.should eq(["0008", "--yes"])
  end

  it "does not chain-validate the tokens after an option-taking command" do
    steps = Facet::CLI.parse_chain(["migrate:down", "--yes", "not-a-command"], chain_known, chain_options)
    steps.size.should eq(1)
    steps.first.flags.should eq(["--yes", "not-a-command"])
  end
end

describe "Facet::Migrate::DbResetCLI.parse" do
  it "accepts --yes and -y as the skip-confirmation flag" do
    Facet::Migrate::DbResetCLI.parse(["--yes"]).assume_yes.should be_true
    Facet::Migrate::DbResetCLI.parse(["-y"]).assume_yes.should be_true
  end

  it "defaults to asking for confirmation" do
    Facet::Migrate::DbResetCLI.parse([] of String).assume_yes.should be_false
  end

  it "raises on an unknown flag before the command could run" do
    expect_raises(OptionParser::InvalidOption) do
      Facet::Migrate::DbResetCLI.parse(["--nope"])
    end
  end
end

describe "Facet::Migrate.ask (confirmation gate)" do
  it "refuses when stdin is not a terminal" do
    Facet::Migrate.ask(tty: false).should eq(Facet::Migrate::ConfirmResult::NeedsTerminal)
  end

  it "prints the prompt and accepts y and yes" do
    ["y\n", "Y\n", "yes\n", "  YES  \n"].each do |answer|
      input = IO::Memory.new(answer)
      output = IO::Memory.new
      result = Facet::Migrate.ask(tty: true, input: input, output: output)
      result.should eq(Facet::Migrate::ConfirmResult::Accepted)
      output.to_s.should contain("Proceed? [y/N]")
    end
  end

  it "declines any other answer and an empty stream" do
    ["n\n", "\n", ""].each do |answer|
      result = Facet::Migrate.ask(tty: true, input: IO::Memory.new(answer), output: IO::Memory.new)
      result.should eq(Facet::Migrate::ConfirmResult::Declined)
    end
  end
end
