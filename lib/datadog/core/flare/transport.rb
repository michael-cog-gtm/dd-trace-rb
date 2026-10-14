# frozen_string_literal: true

require_relative "../transport/request"
require_relative "../transport/transport"
require_relative "../transport/http/client"
require_relative "../transport/http/env"

module Datadog
  module Core
    module Flare
      module Transport
        class Request < Core::Transport::Request
          attr_reader :form

          def initialize(form)
            @form = form
            super(nil)
          end
        end

        class Client < Core::Transport::HTTP::Client
          def build_env(request)
            Core::Transport::HTTP::Env.new(request, form: request.form)
          end
        end

        class Transport < Core::Transport::Transport
          self.http_client_class = Client

          def send_flare(form)
            client.send_request(:flare, Request.new(form))
          end
        end
      end
    end
  end
end
