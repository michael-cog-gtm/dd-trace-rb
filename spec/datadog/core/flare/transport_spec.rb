# frozen_string_literal: true

require "spec_helper"
require "datadog/core/flare/transport/http"

RSpec.describe Datadog::Core::Flare::Transport::HTTP do
  it "posts multipart uploads to the tracer flare endpoint" do
    expect(described_class::FLARE_ENDPOINT.verb).to eq(:post)
    expect(described_class::FLARE_ENDPOINT.path).to eq("/tracer_flare/v1")
  end
end
