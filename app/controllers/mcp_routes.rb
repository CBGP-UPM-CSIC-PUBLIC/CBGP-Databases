# frozen_string_literal: true

require 'json'
require 'rack/utils'

# The HTTP face of the MCP layer (lib/mcp): one JSON-RPC endpoint, POST /mcp,
# for an agent (not a browser), so it sits outside the session login and is
# guarded by a shared bearer token instead. Deliberately minimal: the whole
# deployment lives behind the institute VPN; the token is the fail-closed
# backstop against a network misconfiguration.
module Mcp
  module Routes
    def self.registered(app)
      # Prepare what the tools keep about the ontology in the background, so the first question is as quick as the rest.
      Thread.new { Mcp::Records.warm_up } unless ENV['MCP_TOKEN'].to_s.strip.empty?

      app.post '/mcp' do
        content_type :json
        halt 503, { error: 'MCP is disabled: MCP_TOKEN is not configured on the server' }.to_json if ENV['MCP_TOKEN'].to_s.strip.empty?

        supplied = request.env['HTTP_AUTHORIZATION'].to_s.sub(/\ABearer\s+/i, '')
        halt 401, { error: 'Missing or invalid bearer token' }.to_json unless Rack::Utils.secure_compare(supplied, ENV['MCP_TOKEN'].to_s)

        payload = begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          halt 400, Mcp::Server.error_response(nil, Mcp::Server::PARSE_ERROR, 'Invalid JSON').to_json
        end

        response = Mcp::Server.handle(payload)
        if response.nil?
          status 202
          body ''
        else
          JSON.generate(response)
        end
      end

      # Streamable HTTP lets a client open an event stream with GET; this
      # server never pushes anything, so say so plainly.
      app.get('/mcp') { halt 405, { 'Allow' => 'POST' }, 'MCP over POST only' }
    end
  end
end
