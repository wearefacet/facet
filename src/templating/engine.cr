# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Templating
    # Compile-cache and render entry point around Crinja.
    #
    # One shared `Crinja` environment serves every template. Compile and
    # render are serialised on a mutex — a render is microseconds, and the
    # callers already hold a database transaction, so contention is not a
    # factor.
    module Engine
      @@mutex = Mutex.new(:checked)
      @@cache = {} of String => Crinja::Template
      @@env : Crinja? = nil

      # Collects the root variable names referenced by a template, for
      # authoring-time validation. Only `{{ ... }}` expressions are walked —
      # variables used inside tag arguments (`{% if %}`, `{% for %}`) are not
      # visible to the AST and are not validated.
      def self.roots(source : String) : Array(String)
        template = compile(source)
        acc = Set(String).new
        collect(template.nodes, acc)
        acc.to_a.sort
      end

      # Compiles (or fetches from cache) a template. Raises `Error` on
      # invalid syntax.
      def self.compile(source : String) : Crinja::Template
        fetch_or_compile(source)
      end

      # Renders a template with the given bindings. Raises `Error` on
      # runtime failures.
      def self.render(source : String, bindings : Crinja::Variables) : String
        template = fetch_or_compile(source)
        @@mutex.synchronize do
          begin
            template.render(bindings)
          rescue ex : Crinja::Error
            raise Error.new("Template render failed for #{source.inspect}: #{ex.message}")
          end
        end
      end

      # Callers must hold the mutex: this method locks it. The environment
      # is built lazily on first use, under the same lock.
      private def self.fetch_or_compile(source : String) : Crinja::Template
        @@mutex.synchronize do
          cached = @@cache[source]?
          return cached if cached

          env = (@@env ||= build_env)

          template = begin
            env.from_string(source)
          rescue ex : Crinja::Error
            raise Error.new("Invalid template #{source.inspect}: #{ex.message}")
          end
          @@cache[source] = template
          template
        end
      end

      # One environment, autoescape off — templates produce plain text.
      #
      # Crinja 0.9.0 bug: the `config.autoescape = Bool` setter is inverted
      # (`false` turns autoescape ON, and every rendered string then goes
      # through `HTML.escape` — `'` becomes `&#39;`). Assign the
      # `Autoescape::DISABLED` constant directly. Do not use the Bool setter.
      private def self.build_env : Crinja
        e = Crinja.new
        e.config.autoescape = Crinja::Config::Autoescape::DISABLED
        e
      end

      private def self.collect(node : Crinja::AST::ASTNode, acc : Set(String)) : Nil
        case node
        when Crinja::AST::NodeList
          node.children.each { |child| collect(child, acc) }
        when Crinja::AST::PrintStatement
          collect(node.expression, acc)
        when Crinja::AST::TagNode
          collect(node.block, acc)
        when Crinja::AST::ExpressionNode
          collect_expression(node, acc)
        end
      end

      private def self.collect_expression(node : Crinja::AST::ASTNode, acc : Set(String)) : Nil
        case node
        when Crinja::AST::Expressions, Crinja::AST::ExpressionList,
             Crinja::AST::ArrayLiteral, Crinja::AST::TupleLiteral
          node.children.each { |child| collect_expression(child, acc) }
        when Crinja::AST::IdentifierLiteral
          acc << node.name
        when Crinja::AST::MemberExpression, Crinja::AST::IndexExpression,
             Crinja::AST::FilterExpression, Crinja::AST::TestExpression,
             Crinja::AST::CallExpression
          collect_target_expression(node, acc)
        when Crinja::AST::BinaryExpression, Crinja::AST::ComparisonExpression
          collect_expression(node.left, acc)
          collect_expression(node.right, acc)
        when Crinja::AST::UnaryExpression
          collect_expression(node.right, acc)
        when Crinja::AST::DictLiteral
          node.children.each do |key, value|
            collect_expression(key, acc)
            collect_expression(value, acc)
          end
        end
      end

      # Expressions that target another expression: attribute and index
      # access, filters, tests, and calls.
      private def self.collect_target_expression(node : Crinja::AST::ASTNode, acc : Set(String)) : Nil
        case node
        when Crinja::AST::MemberExpression
          collect_expression(node.identifier, acc)
        when Crinja::AST::IndexExpression
          collect_expression(node.identifier, acc)
          collect_expression(node.argument, acc)
        when Crinja::AST::FilterExpression
          collect_expression(node.target, acc)
        when Crinja::AST::TestExpression
          collect_expression(node.target, acc)
        when Crinja::AST::CallExpression
          # A bare identifier is a global function name (`range(3)`), not a
          # variable. An attribute call chain (`obj.fn()`) still yields its
          # root variable.
          collect_expression(node.identifier, acc) unless node.identifier.is_a?(Crinja::AST::IdentifierLiteral)
          collect_expression(node.argumentlist, acc)
        end
      end
    end
  end
end
