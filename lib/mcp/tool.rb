# frozen_string_literal: true

require 'json'

# The MCP layer: a small, generic, read-only query interface over the
# ontology-driven databases, for an LLM agent. Nothing under lib/mcp knows a
# particular form, field or institute - every name it uses comes from the
# ontology at call time, so the same code serves any ontology.
module Mcp
  # Raised by a tool for a problem the CALLER can fix (unknown form, bad
  # date, ambiguous input...). The message is returned to the model as the
  # tool's result, so it should say what was wrong AND what would work.
  class ToolError < StandardError; end

  # What a tool returns when it has more to say than one JSON document: +data+
  # is serialized as the usual text block, +blocks+ are extra MCP content
  # blocks (e.g. an HTML widget) appended after it.
  Result = Struct.new(:data, :blocks)

  # Base class of every tool. A subclass declares its contract with the class
  # macros below and implements +self.run(args)+; it is registered
  # automatically on definition.
  #
  #   class Thing < Mcp::Tool
  #     tool_name   'thing'
  #     description 'what it does, when to use it, exact examples'
  #     param :form, type: 'string', description: '...', required: true
  #     def self.run(args) = { ... }
  #   end
  class Tool
    SUMMARY_MAX = 140

    LANGUAGE_PARAM = {
      type: 'string', enum: %w[en es],
      description: 'Language of labels in the answer ("en" or "es"). Use the language the user wrote in. Default "en".'
    }.freeze

    class << self
      def registry
        Tool.instance_variable_get(:@registry) || Tool.instance_variable_set(:@registry, [])
      end

      def inherited(subclass)
        super
        Tool.registry << subclass
      end

      def tool_name(name = nil)
        name ? @tool_name = name : @tool_name
      end

      # One self-contained sentence (<= SUMMARY_MAX chars) saying what the tool
      # does and when to use it. It is always the FIRST line of the published
      # description, so a client that abbreviates descriptions (to save
      # tokens) still shows the essential point.
      def summary(text = nil)
        text ? @summary = text.strip : @summary
      end

      # A few words naming the tool for a person (MCP "title").
      def title(text = nil)
        text ? @title = text.strip : @title
      end

      # The detail that follows the summary: what the parameters mean and one
      # worked example. Rules that hold for every tool belong in Mcp::INSTRUCTIONS.
      def description(text = nil)
        text ? @description = text.strip : @description
      end

      # Ask for what the data is (:dataset) or that plus the list of forms
      # (:forms) to be shown right after the summary. Built from the ontology
      # (Mcp::Catalog) each time the tool list is requested, so the text a model
      # chooses tools by always matches the data.
      def context(kind = nil)
        kind ? @context = kind : @context
      end

      def full_description
        [summary, (Mcp::Catalog.context_text(@context) if @context), description].compact.reject(&:empty?).join("\n\n")
      end

      def params
        @params ||= {}
      end

      # +required: true+ makes the parameter mandatory. An Array is instead the object parameter's own list of
      # required properties, passed on in its schema.
      def param(name, required: false, **schema)
        if required.is_a?(Array)
          schema[:required] = required
          required = false
        end
        params[name.to_s] = { schema: schema, required: required }
      end

      def input_schema
        props = params.transform_values { |p| p[:schema] }
        props['language'] = LANGUAGE_PARAM
        { type: 'object', properties: props, required: params.select { |_, p| p[:required] }.keys }
      end

      # Every tool here only reads: say so, in the standard annotations, so a
      # client can treat the whole server as safe to auto-approve.
      ANNOTATIONS = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }.freeze

      def definition
        { name: tool_name, title: title, description: full_description, inputSchema: input_schema,
          annotations: ANNOTATIONS.merge(title: title) }
      end

      def find(name)
        registry.find { |t| t.tool_name == name }
      end

      # Runs the tool for one request and returns MCP content blocks. Scopes
      # the UI language to this call (the same Thread.current[:language] the
      # web UI uses, so every label lookup follows it) and restores it after.
      def invoke(args)
        args = {} unless args.is_a?(Hash)
        missing = params.select { |name, p| p[:required] && blank?(args[name]) }.keys
        raise ToolError, "Missing required argument(s): #{missing.join(', ')}." unless missing.empty?

        previous = Thread.current[:language]
        language = args['language'].to_s.strip.downcase
        Thread.current[:language] = %w[en es].include?(language) ? language : 'en'
        outcome = run(args)
        outcome = Result.new(outcome, []) unless outcome.is_a?(Result)
        [{ type: 'text', text: JSON.generate(outcome.data) }] + Array(outcome.blocks)
      ensure
        Thread.current[:language] = previous
      end

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
      end

      def run(_args)
        raise NotImplementedError, "#{name} must implement run"
      end
    end
  end
end
