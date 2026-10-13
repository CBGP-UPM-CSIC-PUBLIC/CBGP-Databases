# frozen_string_literal: true

# The MCP protocol layer (lib/mcp/server.rb, lib/mcp/tool.rb): what a client
# sees of the JSON-RPC dispatch, tool errors, and language scoping. Uses a
# throwaway tool, so nothing here depends on the ontology or the databases.
RSpec.describe Mcp::Server do
  let(:echo_tool) do
    Class.new(Mcp::Tool) do
      tool_name 'echo_for_spec'
      description 'Echoes its text.'
      param :text, type: 'string', required: true, description: 'what to echo'
      param :mode, type: 'string'

      def self.run(args)
        raise Mcp::ToolError, 'Mode must be loud or quiet.' if args['mode'] == 'bad'
        raise 'secret internal detail' if args['mode'] == 'crash'
        return Mcp::Result.new({ text: args['text'] }, [{ type: 'resource', resource: { uri: 'ui://x', mimeType: 'text/html', text: '<p>x</p>' } }]) if args['mode'] == 'widget'

        { echoed: args['text'], language: Thread.current[:language] }
      end
    end
  end

  before { echo_tool }
  after { Mcp::Tool.registry.delete(echo_tool) }

  def rpc(method, params = nil, id: 1)
    message = { 'jsonrpc' => '2.0', 'id' => id, 'method' => method }
    message['params'] = params if params
    described_class.handle(message)
  end

  def call(arguments, name: 'echo_for_spec')
    rpc('tools/call', { 'name' => name, 'arguments' => arguments })[:result]
  end

  describe 'initialize' do
    it 'agrees a protocol version the client asked for, and carries the instructions' do
      result = rpc('initialize', { 'protocolVersion' => '2025-03-26' })[:result]
      expect(result[:protocolVersion]).to eq('2025-03-26')
      expect(result[:instructions]).to start_with(Mcp::INSTRUCTIONS.strip)
      expect(result[:capabilities]).to eq(tools: { listChanged: false })
    end

    it 'falls back to the newest version it knows when asked for an unknown one' do
      expect(rpc('initialize', { 'protocolVersion' => '1999-01-01' })[:result][:protocolVersion]).to eq(Mcp::Server::SUPPORTED_VERSIONS.first)
    end
  end

  describe 'tools/list' do
    it 'describes every registered tool, with the shared language argument added' do
      tool = rpc('tools/list')[:result][:tools].find { |t| t[:name] == 'echo_for_spec' }
      expect(tool[:description]).to eq('Echoes its text.')
      expect(tool[:inputSchema][:required]).to eq(['text'])
      expect(tool[:inputSchema][:properties].keys).to eq(%w[text mode language])
      expect(tool[:inputSchema][:properties]['language'][:enum]).to eq(%w[en es])
    end

    it 'lists the real tools, each with a description long enough to teach a small model' do
      real = Mcp::Tool.registry.reject { |t| t == echo_tool }
      expect(real.map(&:tool_name)).to include('describe_form', 'search_records', 'get_record', 'linked_records', 'record_history', 'render_timeline')
      expect(real.map { |t| t.description.length }.min).to be > 200
    end
  end

  describe 'tools/call' do
    it 'returns the tool result as one JSON text block' do
      result = call({ 'text' => 'hi' })
      expect(result[:isError]).to be false
      expect(JSON.parse(result[:content].first[:text])).to eq('echoed' => 'hi', 'language' => 'en')
    end

    it 'appends extra content blocks after the text block' do
      result = call({ 'text' => 'hi', 'mode' => 'widget' })
      expect(result[:content].map { |b| b[:type] }).to eq(%w[text resource])
      expect(result[:content].last[:resource][:mimeType]).to eq('text/html')
    end

    it 'reports a missing required argument by name, as a tool error the model can read' do
      result = call({})
      expect(result[:isError]).to be true
      expect(result[:content].first[:text]).to include('Missing required argument(s): text')
    end

    it 'treats a blank required argument as missing' do
      expect(call({ 'text' => '   ' })[:isError]).to be true
    end

    it 'passes a ToolError message through verbatim' do
      expect(call({ 'text' => 'x', 'mode' => 'bad' })[:content].first[:text]).to eq('Error: Mode must be loud or quiet.')
    end

    it 'logs that a call was rejected, never why (the reason can echo what the caller sent)' do
      expect(described_class).to receive(:warn).with('[MCP] echo_for_spec rejected')
      call({ 'text' => 'Álvarez Alfageme', 'mode' => 'bad' })
    end

    it 'turns an unexpected failure into a generic message that leaks nothing' do
      allow(Kernel).to receive(:warn)
      result = call({ 'text' => 'x', 'mode' => 'crash' })
      expect(result[:isError]).to be true
      expect(result[:content].first[:text]).not_to include('secret internal detail')
      expect(result[:content].first[:text]).to include('do not guess')
    end

    it 'names the available tools when asked for one that does not exist' do
      result = call({}, name: 'nope')
      expect(result[:isError]).to be true
      expect(result[:content].first[:text]).to include("Unknown tool 'nope'", 'echo_for_spec')
    end

    it 'scopes the language to one call and restores it afterwards' do
      Thread.current[:language] = 'en'
      expect(JSON.parse(call({ 'text' => 'x', 'language' => 'es' })[:content].first[:text])['language']).to eq('es')
      expect(Thread.current[:language]).to eq('en')
    end

    it 'ignores a language it does not support' do
      expect(JSON.parse(call({ 'text' => 'x', 'language' => 'fr' })[:content].first[:text])['language']).to eq('en')
    end

    it 'tolerates arguments that are not an object' do
      expect(call('nonsense')[:isError]).to be true
    end
  end

  describe 'protocol edges' do
    it 'answers ping' do
      expect(rpc('ping')[:result]).to eq({})
    end

    it 'sends nothing back for a notification' do
      expect(described_class.handle({ 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' })).to be_nil
    end

    it 'rejects an unknown method with the standard code' do
      expect(rpc('resources/list')[:error][:code]).to eq(Mcp::Server::METHOD_NOT_FOUND)
    end

    it 'rejects a body that is not an object' do
      expect(described_class.handle('x')[:error][:code]).to eq(Mcp::Server::INVALID_REQUEST)
    end

    it 'answers every request in a batch and skips notifications' do
      replies = described_class.handle([
                                         { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'ping' },
                                         { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' },
                                         { 'jsonrpc' => '2.0', 'id' => 2, 'method' => 'ping' }
                                       ])
      expect(replies.map { |r| r[:id] }).to eq([1, 2])
    end
  end
end

# Descriptors are written for a small model behind a client that may show only
# name + description in a cheap listing and fetch the full schema on demand
# (Hermes' tool search): the summary must carry the choice of tool on its own,
# and the details a call needs must live in the schema.
RSpec.describe 'MCP tool descriptors' do
  let(:tools) { Mcp::Tool.registry.reject { |t| t.tool_name.to_s.end_with?('_for_spec') } }

  it 'give every tool a one-line summary of at most the allowed length, as the first line of its description' do
    tools.each do |tool|
      expect(tool.summary).not_to be_nil, "#{tool.tool_name} has no summary"
      expect(tool.summary).not_to include("\n")
      expect(tool.summary.length).to be <= Mcp::Tool::SUMMARY_MAX, "#{tool.tool_name} summary is #{tool.summary.length} chars"
      expect(tool.definition[:description].lines.first.strip).to eq(tool.summary)
    end
  end

  it 'give every tool a title and mark it read-only' do
    tools.each do |tool|
      definition = tool.definition
      expect(definition[:title]).not_to be_nil
      expect(definition[:annotations]).to include(readOnlyHint: true, destructiveHint: false)
    end
  end

  it 'keep the whole name-and-summary listing small' do
    expect(tools.sum { |t| t.tool_name.length + t.summary.length }).to be < 1300 # about 130 characters a tool: still a cheap listing
  end

  it 'describe every parameter, so the schema alone is enough to make a call' do
    tools.each do |tool|
      tool.input_schema[:properties].each do |name, schema|
        expect(schema[:description]).not_to be_nil, "#{tool.tool_name}.#{name} has no description"
      end
    end
  end

  it 'spell out the structure of array parameters (no bare object items)' do
    tools.each do |tool|
      tool.input_schema[:properties].each do |name, schema|
        next unless schema[:type] == 'array' && schema[:items] && schema[:items][:type] == 'object'

        expect(schema[:items][:properties]).not_to be_nil, "#{tool.tool_name}.#{name} items have no properties"
      end
    end
  end

  it 'offer the search operators as an enum' do
    where = Mcp::Tools::SearchRecords.input_schema[:properties]['where']
    expect(where[:items][:properties][:op][:enum]).to eq(Mcp::Records::OPS.keys)
  end
end
