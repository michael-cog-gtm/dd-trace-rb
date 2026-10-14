# frozen_string_literal: true

require "json"
require_relative "../remote/dispatcher"

module Datadog
  module Core
    module Flare
      module Remote
        PRODUCTS = ["AGENT_CONFIG", "AGENT_TASK"].freeze

        class << self
          def products
            PRODUCTS
          end

          def capabilities
            []
          end

          def receivers(_telemetry)
            matcher = Core::Remote::Dispatcher::Matcher::Product.new(PRODUCTS)
            [
              Core::Remote::Dispatcher::Receiver.new(matcher) do |_repository, changes|
                process_changes(changes)
              end,
            ]
          end

          def process_changes(changes)
            component = Datadog.send(:components, allow_initialization: false)&.flare
            begin
              component&.check_stale!
            rescue => e
              Datadog.logger.debug { "Flare: failed to check for stale log capture: #{e.class}: #{e.message}" }
            end

            ordered_changes = changes.each_with_index.sort_by do |change, index|
              [(change.path.product == "AGENT_CONFIG") ? 0 : 1, index]
            end

            ordered_changes.each do |change, _index|
              process_change(component, change)
            rescue => e
              Datadog.logger.debug { "Flare: failed to process remote config change: #{e.class}: #{e.message}" }
              case change
              when Core::Remote::Configuration::Repository::Change::Inserted,
                  Core::Remote::Configuration::Repository::Change::Updated
                change.content.errored("#{e.class}: #{e.message}")
              end
            end
          end

          private

          def process_change(component, change)
            case change
            when Core::Remote::Configuration::Repository::Change::Inserted,
                Core::Remote::Configuration::Repository::Change::Updated
              process_content(component, change)
            when Core::Remote::Configuration::Repository::Change::Deleted
              process_delete(component, change)
            end
          end

          def process_content(component, change)
            content = change.content

            if change.path.product == "AGENT_CONFIG" && change.path.config_id == "configuration_order"
              content.applied
              return
            end

            data = JSON.parse(content.data)
            raise TypeError, "remote config payload must be a JSON object" unless data.is_a?(Hash)

            if change.path.product == "AGENT_CONFIG"
              process_config(component, change.path.config_id, data)
            else
              process_task(component, data)
            end

            content.applied
          end

          def process_config(component, config_id, data)
            config = data["config"]
            level = config["log_level"] if config.is_a?(Hash)

            if level.is_a?(String)
              component&.prepare(level, config_id: config_id)
            else
              component&.revert(config_id: config_id)
            end
          end

          def process_task(component, data)
            return unless data["task_type"] == "tracer_flare"

            args = data["args"]
            return unless args.is_a?(Hash)

            case_id = args["case_id"]
            unless valid_case_id?(case_id)
              Datadog.logger.debug { "Flare: ignoring task with invalid case_id" }
              return
            end

            component&.send_flare(
              case_id: case_id,
              hostname: args["hostname"].to_s,
              email: args["user_handle"].to_s,
              uuid: data["uuid"].to_s,
            )
          end

          def process_delete(component, change)
            return unless change.path.product == "AGENT_CONFIG"

            component&.revert(config_id: change.path.config_id)
          end

          def valid_case_id?(case_id)
            case_id.is_a?(String) &&
              !case_id.empty? &&
              case_id != "0" &&
              case_id.match?(/\A\d+(?:-(?:with-debug|with-content))?\z/)
          end
        end
      end
    end
  end
end
