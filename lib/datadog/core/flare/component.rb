# frozen_string_literal: true

require "json"
require "stringio"
require_relative "log_capture"
require_relative "zip_writer"
require_relative "transport/http"
require_relative "../diagnostics/environment_logger"
require_relative "../../tracing/diagnostics/environment_logger"
require_relative "../utils/time"
require_relative "../vendor/multipart-post/multipart/post/composite_read_io"

module Datadog
  module Core
    module Flare
      class Component
        STALE_DURATION_SECONDS = 20 * 60
        LOG_LEVELS = {
          "trace" => ::Logger::DEBUG,
          "debug" => ::Logger::DEBUG,
          "info" => ::Logger::INFO,
          "warn" => ::Logger::WARN,
          "error" => ::Logger::ERROR,
          "critical" => ::Logger::FATAL,
        }.freeze

        def self.build(settings, agent_settings, logger:)
          return unless settings.remote.enabled

          new(settings: settings, agent_settings: agent_settings, logger: logger)
        end

        def initialize(settings:, agent_settings:, logger:)
          @settings = settings
          @agent_settings = agent_settings
          @logger = logger
          @mutex = Mutex.new
          @capture = nil
          @config_id = nil
          @original_level = nil
          @level_name = nil
          @started_at = nil
          @transport = nil
        end

        def prepare(level_name, config_id:)
          @mutex.synchronize do
            if @capture
              @logger.debug { "Flare: already collecting logs" }
              return false
            end

            flare_level = LOG_LEVELS[level_name.downcase]
            unless flare_level
              @logger.debug { "Flare: invalid level #{level_name.inspect}" }
              return false
            end

            original_level = @logger.level
            @original_level = original_level
            @logger.level = [original_level, flare_level].min
            capture = LogCapture.new(level: flare_level)
            @capture = capture
            capture.attach(@logger)
            @config_id = config_id
            @level_name = level_name.downcase
            @started_at = Core::Utils::Time.get_time
            @logger.debug { "Flare: started collecting logs at level #{level_name}" }
            true
          end
        end

        def revert(config_id: nil)
          @mutex.synchronize do
            return unless @capture
            return if config_id && config_id != @config_id

            revert_locked
          end
        end

        def check_stale!
          @mutex.synchronize do
            return unless @capture

            started_at = @started_at
            return unless started_at
            return unless Core::Utils::Time.get_time - started_at >= STALE_DURATION_SECONDS

            revert_locked
          end
        end

        def send_flare(case_id:, hostname:, email:, uuid:)
          logs = ""
          level_name = "debug"
          @mutex.synchronize do
            capture = @capture
            logs = capture ? capture.contents : ""
            level_name = @level_name || "debug"
            revert_locked if capture
          end

          zip = ZipWriter.build(
            [
              ["tracer_ruby_#{Process.pid}.log", logs],
              ["tracer_config_#{Process.pid}.json", JSON.pretty_generate(configs: config_dump)],
            ],
          )
          form = {
            "source" => "tracer_ruby",
            "case_id" => case_id,
            "hostname" => hostname,
            "email" => email,
            "uuid" => uuid,
            "flare_file" => Core::Vendor::Multipart::Post::UploadIO.new(
              StringIO.new(zip),
              "application/octet-stream",
              "tracer-ruby-#{case_id}-#{Core::Utils::Time.now.to_i}-#{level_name}.zip",
            ),
          }

          response = transport.send_flare(form)
          if response.is_a?(Core::Transport::InternalErrorResponse)
            @logger.warn { "Flare: failed to send tracer flare: #{response.inspect}" }
            false
          else
            code = response.code
            if code && (200..299).cover?(code)
              @logger.info { "Flare: sent tracer flare for case #{case_id}" }
              true
            else
              @logger.warn { "Flare: failed to send tracer flare for case #{case_id}: #{code}" }
              false
            end
          end
        rescue => e
          @logger.warn { "Flare: failed to send tracer flare: #{e.class}: #{e.message}" }
          false
        end

        def shutdown!
          revert
        end

        private

        def revert_locked
          capture = @capture
          return unless capture

          capture.detach(@logger)
          original_level = @original_level
          @logger.level = original_level if original_level
          @capture = nil
          @config_id = nil
          @original_level = nil
          @level_name = nil
          @started_at = nil
          nil
        end

        def transport
          @transport ||= Transport::HTTP.flare(agent_settings: @agent_settings, logger: @logger)
        end

        def config_dump
          core_config = collect_config { Core::Diagnostics::EnvironmentCollector.collect_config! }
          tracing_config = collect_config { Tracing::Diagnostics::EnvironmentCollector.collect_config! }
          core_config.merge(tracing_config)
        end

        def collect_config
          yield
        rescue => e
          {error: e.class.to_s}
        end
      end
    end
  end
end
