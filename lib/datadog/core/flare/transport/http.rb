# frozen_string_literal: true

require_relative "../../transport/http"
require_relative "../transport"

module Datadog
  module Core
    module Flare
      module Transport
        module HTTP
          FLARE_ENDPOINT = Core::Transport::HTTP::API::Endpoint.new(
            :post,
            "/tracer_flare/v1",
          )

          def self.flare(agent_settings:, logger:)
            Core::Transport::HTTP.build(
              logger: logger,
              agent_settings: agent_settings,
            ) do |transport|
              transport.api "flare", FLARE_ENDPOINT, default: true
            end.to_transport(Flare::Transport::Transport)
          end
        end
      end
    end
  end
end
