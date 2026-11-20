# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Shared HTTP request helpers ──────────────────────────────────────────────
#
# Convenience functions for making HTTP requests through the Kemal test chain.
# These are top-level functions available in every spec that requires this file.
#
# Usage:
#   require "../support/http_helper"   # for call_api, chain_handlers
#   require "../support/http_helpers"  # for the helpers below

# Builds a Bearer `Authorization` header for the given credential
# (session token, API key, or app token). Callers that also need CSRF
# or content-type headers add them on the returned value:
#
#   headers = bearer_headers(token)
#   headers["X-Requested-With"] = "XMLHttpRequest"
def bearer_headers(token : String) : HTTP::Headers
  HTTP::Headers{"Authorization" => "Bearer #{token}"}
end

# Adds the CSRF header browser clients send alongside a session token.
def with_xrw(headers : HTTP::Headers) : HTTP::Headers
  headers["X-Requested-With"] = "XMLHttpRequest"
  headers
end

# Adds the form content type the OAuth token/authorize POST endpoints read.
def with_form_auth(headers : HTTP::Headers) : HTTP::Headers
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  headers
end

# Every request helper below takes optional headers and passes them to
# the request. The default is an empty `HTTP::Headers`, so existing call
# sites stay valid with no change.

# Create a core.Domain document via HTTP
def create_domain_http(domain : String, description : String = "", headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  create_document_http("core", "Domain", %({ "id": #{domain.to_json}, "description": #{description.to_json} }), headers)
end

# Create a doctype via HTTP (POST /Api/core/DocType)
def create_doctype_http(json_body : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("POST", "/Api/core/DocType", headers, body: json_body)
  call_api(request)
end

# Create a document of any doctype via HTTP
def create_document_http(domain : String, doc_type : String, json_body : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{doc_type}", headers, body: json_body)
  call_api(request)
end

# Create a child document via nested route (POST /Api/:domain/:doctype/:id/:rel)
def create_child_document_http(domain : String, root_doctype : String, root_id : String, child_rel : String, json_body : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{root_doctype}/#{root_id}/#{child_rel}", headers, body: json_body)
  call_api(request)
end

# Execute a named action on a document via HTTP
def execute_action_http(domain : String, doc_type : String, doc_id : String, action_name : String, args_body : String = "{}", headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("POST", "/Api/#{domain}/#{doc_type}/#{doc_id}/#{action_name}", headers, body: args_body)
  call_api(request)
end

# Read a document via HTTP (GET /Api/:domain/:doctype/:id)
def get_document_http(domain : String, doc_type : String, doc_id : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doc_type}/#{doc_id}", headers)
  call_api(request)
end

# List documents via HTTP (GET /Api/:domain/:doctype?<query>)
def list_documents_http(domain : String, doc_type : String, query : String = "", headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doc_type}?#{query}", headers)
  call_api(request)
end

# List child documents via nested route (GET /Api/:domain/:doctype/:id/:rel)
def list_nested_http(domain : String, doc_type : String, doc_id : String, rel_name : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doc_type}/#{doc_id}/#{rel_name}", headers)
  call_api(request)
end

# Read a specific child document (GET /Api/:domain/:doctype/:id/:rel/:child_id)
def read_nested_http(domain : String, doc_type : String, doc_id : String, rel_name : String, child_id : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("GET", "/Api/#{domain}/#{doc_type}/#{doc_id}/#{rel_name}/#{child_id}", headers)
  call_api(request)
end

# Update a document via HTTP (PATCH /Api/:domain/:doctype/:id)
def patch_document_http(domain : String, doc_type : String, doc_id : String, json_body : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("PATCH", "/Api/#{domain}/#{doc_type}/#{doc_id}", headers, body: json_body)
  call_api(request)
end

# Delete a document via HTTP (DELETE /Api/:domain/:doctype/:id)
def delete_document_http(domain : String, doc_type : String, doc_id : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
  request = HTTP::Request.new("DELETE", "/Api/#{domain}/#{doc_type}/#{doc_id}", headers)
  call_api(request)
end

# Creates a draft core.Domain via the public HTTP route and returns its id.
def create_draft_via_api : String
  resp = call_api(HTTP::Request.new(
    "POST",
    "/Api/core/Domain/draft",
    body: "{}",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
  ))
  assert_http_status(resp, 201)
  JSON.parse(resp.body)["meta"]["id"].as_s
end

# Parse an HTTP response body as JSON
def parse_body(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

# Creates a document and extracts its `id`, asserting the response was 201.
# On failure, prints the response body for debugging before failing.
def create_doc_id_http(domain : String, doc_type : String, json_body : String) : String
  resp = create_document_http(domain, doc_type, json_body)
  if resp.status_code != 201
    STDERR.puts "─" * 70
    STDERR.puts "create_doc_id_http: expected 201, got #{resp.status_code} for POST /Api/#{domain}/#{doc_type}"
    STDERR.puts "Request body: #{json_body}"
    STDERR.puts "Response body: #{resp.body}"
    STDERR.puts "─" * 70
  end
  resp.status_code.should eq(201)
  body = parse_body(resp)
  body["meta"]["id"].as_s
end

# This is an alias of create_doc_id_http for creating child documents.
def create_child_doc_id_http(domain : String, root_doctype : String, root_id : String, child_rel : String, json_body : String) : String
  resp = create_child_document_http(domain, root_doctype, root_id, child_rel, json_body)
  if resp.status_code != 201
    STDERR.puts "─" * 70
    STDERR.puts "create_child_doc_id_http: expected 201, got #{resp.status_code} for POST /Api/#{domain}/#{root_doctype}/#{root_id}/#{child_rel}"
    STDERR.puts "Request body: #{json_body}"
    STDERR.puts "Response body: #{resp.body}"
    STDERR.puts "─" * 70
  end
  resp.status_code.should eq(201)
  body = parse_body(resp)
  body["meta"]["id"].as_s
end
