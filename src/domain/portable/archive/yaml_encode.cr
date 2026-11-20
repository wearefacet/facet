# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "yaml"
require "../../../util/yaml_json"

module Facet
  module Domain
    module Portable
      module Archive
        # YAML to JSON conversion for bundle entry data.
        #
        # `read_entry_yaml` parses an entry file with `Util::YamlInclude`,
        # then converts the parsed value to `JSON::Any`. The conversion is
        # generic code. It lives in `Util::YamlJson`. This method is the
        # archive-side call point.
        private def self.yaml_to_json_any(value : YAML::Any) : JSON::Any
          Facet::Util::YamlJson.to_json_any(value)
        end
      end
    end
  end
end
