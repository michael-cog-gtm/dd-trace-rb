# frozen_string_literal: true

require "logger"
require "time"
require_relative "../utils/time"

module Datadog
  module Core
    module Flare
      class LogCapture
        MAX_BYTES = 2 * 1024 * 1024
        TRUNCATED_MESSAGE = "[datadog flare] log capture truncated\n"
        LABELS = %w[DEBUG INFO WARN ERROR FATAL ANY].freeze

        def initialize(level:, max_bytes: MAX_BYTES)
          @level = level
          @max_bytes = max_bytes
          @lines = []
          @byte_count = 0
          @truncated = false
          @mutex = Mutex.new
          @attached_logger = nil
          @installed_methods = false
        end

        def attach(logger)
          return false unless logger.respond_to?(:add)
          return false if logger.singleton_methods(false).include?(:add)
          return false if logger.singleton_methods(false).include?(:log)

          original = logger.method(:add)
          record = method(:record)
          level = @level
          logger.define_singleton_method(:add) do |severity, message = nil, progname = nil, &block|
            if severity >= level
              used_progname = message.nil? && !block
              resolved_message = if message.nil?
                block ? block.call : progname
              else
                message
              end
              begin
                record.call(severity, resolved_message)
              rescue
                nil
              end
              original_progname = progname
              original_progname = nil if used_progname || resolved_message.nil?
              original.call(severity, resolved_message, original_progname)
            else
              original.call(severity, message, progname, &block)
            end
          end
          logger.define_singleton_method(:log) do |*args, &block|
            send(:add, *args, &block)
          end

          @attached_logger = logger
          @installed_methods = true
          true
        end

        def detach(logger)
          return unless @installed_methods && @attached_logger.equal?(logger)

          logger.singleton_class.send(:remove_method, :add)
          logger.singleton_class.send(:remove_method, :log)
          @attached_logger = nil
          @installed_methods = false
          nil
        end

        def contents
          @mutex.synchronize { @lines.join.dup }
        end

        def record(severity, message)
          line = "#{Core::Utils::Time.now.utc.iso8601(3)} #{LABELS[severity] || "ANY"} #{message_string(message)}\n"

          @mutex.synchronize do
            return if @truncated

            if @byte_count + line.bytesize > @max_bytes
              @lines << TRUNCATED_MESSAGE
              @byte_count += TRUNCATED_MESSAGE.bytesize
              @truncated = true
            else
              @lines << line
              @byte_count += line.bytesize
            end
          end
        end

        private

        def message_string(message)
          case message
          when String
            message
          when Exception
            "#{message.message} (#{message.class})"
          else
            message.inspect
          end
        end
      end
    end
  end
end
