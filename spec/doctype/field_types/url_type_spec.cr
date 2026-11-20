# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"

module Facet
  module Doctype
    describe UrlType do
      subject = UrlType.new

      it "has type_name 'url'" do
        subject.type_name.should eq("url")
      end

      describe "#validate" do
        fd = FieldDefinition.new(type: UrlType.new)

        it "passes for an http URL" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("http://example.com"), fd, "website", errors)
          errors.should be_empty
        end

        it "passes for an https URL with path and query" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://example.com/users/42?tab=profile"), fd, "website", errors)
          errors.should be_empty
        end

        it "rejects non-string values" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(42), fd, "website", errors)
          errors.map(&.message).should eq(["must be a string"])
        end

        it "rejects a relative path" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("/users/42"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects a non-web scheme" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("ftp://example.com"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects a hostless string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects an empty string" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new(""), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects a host with a space (B-174)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://exa mple.test/x"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects a prefixed scheme-lookalike with stray punctuation (B-174)" do
          # The url widget prefixes `https://` to bare input; the mangled form
          # (`host == "ht!tp"`, path `//bad url`) must not pass the gate.
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://ht!tp://bad url"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "rejects a host with other invalid characters" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://bang!host.test"), fd, "website", errors)
          errors.first.message.should contain("not a valid URL")
        end

        it "accepts a bracketed IPv6 host" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://[2001:db8::1]:8443/x"), fd, "website", errors)
          errors.should be_empty
        end

        it "accepts an IPv4 host and a bare hostname" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://192.168.1.10/x"), fd, "website", errors)
          subject.validate(JSON::Any.new("https://localhost:3000"), fd, "website", errors)
          errors.should be_empty
        end

        it "accepts an underscore host (lenient DNS-style set)" do
          errors = [] of Facet::ValidationError
          subject.validate(JSON::Any.new("https://my_server.local/x"), fd, "website", errors)
          errors.should be_empty
        end
      end

      describe "#normalize" do
        fd = FieldDefinition.new(type: UrlType.new)

        it "completes a dotted bare host with https (B-294)" do
          subject.normalize(JSON::Any.new("www.acme.tld"), fd).as_s.should eq("https://www.acme.tld")
        end

        it "keeps the path and query on a completed bare host" do
          subject.normalize(JSON::Any.new("www.acme.tld/users/42?tab=profile"), fd).as_s
            .should eq("https://www.acme.tld/users/42?tab=profile")
        end

        it "completes a bare host with a port" do
          subject.normalize(JSON::Any.new("www.acme.tld:8443"), fd).as_s
            .should eq("https://www.acme.tld:8443")
        end

        it "trims whitespace as part of the completion" do
          subject.normalize(JSON::Any.new("  www.acme.tld  "), fd).as_s
            .should eq("https://www.acme.tld")
        end

        it "does not complete a dotless host (B-294)" do
          # Free text that reads like a host and single-label hosts must
          # carry their scheme explicitly — `validate` refuses them.
          subject.normalize(JSON::Any.new("not-a-url"), fd).as_s.should eq("not-a-url")
          subject.normalize(JSON::Any.new("localhost:3000"), fd).as_s
            .should eq("localhost:3000")
        end

        it "does not complete a value with a stray-punctuation authority (B-174)" do
          subject.normalize(JSON::Any.new("ht!tp://bad url"), fd).as_s
            .should eq("ht!tp://bad url")
        end

        it "keeps an absolute value untouched" do
          subject.normalize(JSON::Any.new("https://www.acme.tld"), fd).as_s
            .should eq("https://www.acme.tld")
          subject.normalize(JSON::Any.new("http://insecure.example"), fd).as_s
            .should eq("http://insecure.example")
        end

        it "keeps a blank and a non-string value untouched" do
          subject.normalize(JSON::Any.new(""), fd).as_s.should eq("")
          subject.normalize(JSON::Any.new(42), fd).raw.should eq(42)
        end

        it "completed output passes #validate" do
          errors = [] of Facet::ValidationError
          normalized = subject.normalize(JSON::Any.new("www.acme.tld"), fd)
          subject.validate(normalized, fd, "website", errors)
          errors.should be_empty
        end
      end

      describe "#validate_definition" do
        it "adds no errors (no schema-level constraints)" do
          errors = [] of Facet::ValidationError
          fd = FieldDefinition.new(type: UrlType.new)
          subject.validate_definition(fd, "test", errors)
          errors.should be_empty
        end
      end
    end
  end
end
