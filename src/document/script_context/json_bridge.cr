# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../../lua"

module Facet
  module Document
    module ScriptContext
      # ── JSON ↔ Lua value converters ──────────────────────────────────

      def self.json_to_lua_value(value : JSON::Any) : Lua::Engine::Value
        case value.raw
        when Nil
          nil
        when Bool
          value.as_bool
        when Int64
          value.as_i64
        when Float64
          value.as_f
        when String
          value.as_s
        when Array(JSON::Any)
          value.as_a.map { |v| json_to_lua_value(v) }
        when Hash(String, JSON::Any)
          hash = Hash(String, Lua::Engine::Value).new
          value.as_h.each { |k, v| hash[k] = json_to_lua_value(v) }
          hash
        else
          nil
        end
      end

      # ── JSON encode/decode helpers for raw Lua stack values ──────

      # Converts a raw Lua stack value at `index` to a JSON string.
      # Handles nil, boolean, number, string, and table (recursive).
      def self.lua_stack_to_json_string(state : LibLua::State, index : Int32) : String
        json = lua_stack_to_json_any(state, index)
        json.to_json
      end

      # Converts a raw Lua stack value at `index` to a JSON::Any.
      # Shared with `LuaDocumentHelpers`.
      def self.lua_stack_to_json_any(state : LibLua::State, index : Int32) : JSON::Any
        case LibLua.type(state, index)
        when 0 # LUA_TNIL
          JSON::Any.new(nil)
        when 1 # LUA_TBOOLEAN
          JSON::Any.new(LibLua.toboolean(state, index) != 0)
        when 3 # LUA_TNUMBER
          # Try integer first to preserve int64 precision.
          int_val = LibLua.tointegerx(state, index, out is_int)
          if is_int != 0
            JSON::Any.new(int_val.to_i64)
          else
            val = LibLua.tonumberx(state, index, out _unused)
            JSON::Any.new(val)
          end
        when 4 # LUA_TSTRING
          ptr = LibLua.tolstring(state, index, nil)
          str = ptr.null? ? "" : String.new(ptr)
          JSON::Any.new(str)
        when 5 # LUA_TTABLE
          lua_table_to_json_any(state, index)
        else
          JSON::Any.new(nil)
        end
      end

      # Recursively converts a Lua table to a JSON::Any.
      private def self.lua_table_to_json_any(
        state : LibLua::State,
        index : Int32,
      ) : JSON::Any
        abs_idx = LibLua.absindex(state, index)
        obj = {} of String => JSON::Any
        arr = [] of JSON::Any
        has_string_key = false
        max_key = 0_i64
        count = 0_i64

        LibLua.pushnil(state)
        while LibLua.next(state, abs_idx) != 0
          value = lua_stack_to_json_any(state, -1)

          if LibLua.type(state, -2) == 4 # string key
            has_string_key = true
            key_ptr = LibLua.tolstring(state, -2, nil)
            key = key_ptr.null? ? "_" : String.new(key_ptr)
            obj[key] = value
          elsif LibLua.type(state, -2) == 3 # number key
            # Try integer first for precision.
            int_key = LibLua.tointegerx(state, -2, out key_is_int)
            ki = key_is_int != 0 ? int_key.to_i64 : LibLua.tonumberx(state, -2, out _unused).to_i64
            max_key = ki if ki > max_key
            count += 1
            arr << value
          end

          LibLua.settop(state, -2)
        end

        if has_string_key || count == 0 || max_key != count
          JSON::Any.new(obj)
        else
          JSON::Any.new(arr)
        end
      end

      # Recursively pushes a JSON::Any value onto the Lua stack as a Lua value.
      def self.push_json_to_lua_stack(state : LibLua::State, json : JSON::Any) : Nil
        case json.raw
        when Nil
          LibLua.pushnil(state)
        when Bool
          LibLua.pushboolean(state, json.as_bool ? 1 : 0)
        when Int64
          LibLua.pushinteger(state, json.as_i64)
        when Float64
          LibLua.pushnumber(state, json.as_f)
        when String
          LibLua.pushstring(state, json.as_s)
        when Array(JSON::Any)
          ary = json.as_a
          LibLua.createtable(state, ary.size, 0)
          ary.each_with_index do |item, i|
            push_json_to_lua_stack(state, item)
            LibLua.rawseti(state, -2, i + 1)
          end
        when Hash(String, JSON::Any)
          h = json.as_h
          LibLua.createtable(state, 0, h.size)
          h.each do |k, v|
            LibLua.pushstring(state, k)
            push_json_to_lua_stack(state, v)
            LibLua.settable(state, -3)
          end
        else
          LibLua.pushnil(state)
        end
      end

      def self.lua_value_to_json(value : Lua::Engine::Value) : JSON::Any
        case value
        when Nil
          JSON::Any.new(nil)
        when Bool
          JSON::Any.new(value)
        when Int64
          JSON::Any.new(value)
        when Float64
          JSON::Any.new(value)
        when String
          JSON::Any.new(value)
        when Array
          items = value.map { |v| lua_value_to_json(v) }
          JSON::Any.new(items)
        when Hash(String, Lua::Engine::Value)
          h = Hash(String, JSON::Any).new
          value.each { |k, v| h[k] = lua_value_to_json(v) }
          JSON::Any.new(h)
        when ::Lua::Function
          JSON::Any.new(nil)
        else
          JSON::Any.new(nil)
        end
      end

      # ── Lua::Table → JSON string ─────────────────────────────────────
      def self.lua_table_to_json(table : ::Lua::Table) : String
        String.build { |io| emit_lua_table(io, table) }
      end

      private def self.emit_lua_table(io : IO, table : ::Lua::Table) : Nil
        pairs = table.to_a

        all_num_keys = pairs.all?(Float64)
        if all_num_keys
          indices = pairs.map { |(k, _)| k.as(Float64).to_i64 }.sort!
          if indices == (1..indices.size).to_a
            io << '['
            indices.each_with_index do |i, idx|
              io << ',' unless idx == 0
              emit_lua_value(io, table[i.to_f])
            end
            io << ']'
            return
          end
        end

        io << '{'
        first = true
        pairs.each do |k, v|
          io << ',' unless first
          first = false
          emit_lua_string_key(io, k)
          io << ':'
          emit_lua_value(io, v)
        end
        io << '}'
      end

      private def self.emit_lua_value(io : IO, value : ::Lua::Type) : Nil
        case value
        when Nil
          io << "null"
        when Bool
          io << value.to_s
        when Float64
          if value == value.to_i64.to_f
            io << value.to_i64.to_s
          else
            io << value.to_s
          end
        when String
          value.to_json(io)
        when ::Lua::Table
          emit_lua_table(io, value)
        else
          io << "null"
        end
      end

      private def self.emit_lua_string_key(io : IO, key : ::Lua::Type) : Nil
        str = case key
              when String  then key
              when Float64 then key.to_i64.to_s
              when Bool    then key.to_s
              else              key.to_s
              end
        str.to_json(io)
      end
    end
  end
end
