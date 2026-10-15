# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"
require "zlib"
require "datadog/core/flare/component"

RSpec.describe Datadog::Core::Flare::Component do
  let(:settings) { Datadog::Core::Configuration::Settings.new }
  let(:agent_settings) { double("agent settings") }
  let(:output) { StringIO.new }
  let(:logger) { Datadog::Core::Logger.new(output) }
  let(:transport) { instance_double(Datadog::Core::Flare::Transport::Transport) }
  let(:response) { double("response", internal_error?: false, code: 202) }

  subject(:component) { described_class.new(settings: settings, agent_settings: agent_settings, logger: logger) }

  describe ".build" do
    it "does not build when remote configuration is disabled" do
      settings.remote.enabled = false

      expect(described_class.build(settings, agent_settings, logger: logger)).to be_nil
    end

    it "builds when remote configuration is enabled" do
      settings.remote.enabled = true

      expect(described_class.build(settings, agent_settings, logger: logger)).to be_a(described_class)
    end
  end

  before do
    logger.level = ::Logger::INFO
    allow(Datadog::Core::Flare::Transport::HTTP).to receive(:flare).and_return(transport)
    allow(transport).to receive(:send_flare).and_return(response)
  end

  describe "#prepare and #revert" do
    it "lowers the logger level and restores it on revert" do
      expect(component.prepare("trace", config_id: "flare-1")).to be true
      expect(logger.level).to eq(::Logger::DEBUG)

      component.revert

      expect(logger.level).to eq(::Logger::INFO)
    end

    it "preserves an externally changed logger level and detaches the capture" do
      component.prepare("debug", config_id: "flare-1")
      logger.level = ::Logger::WARN

      component.revert

      expect(logger.level).to eq(::Logger::WARN)
      expect(logger.singleton_methods(false)).not_to include(:add, :log)
    end

    it "ignores a second prepare and refuses to revert a different config" do
      component.prepare("debug", config_id: "flare-1")

      expect(component.prepare("info", config_id: "flare-2")).to be false
      component.revert(config_id: "flare-2")
      expect(logger.level).to eq(::Logger::DEBUG)

      component.revert(config_id: "flare-1")
      expect(logger.level).to eq(::Logger::INFO)
    end

    it "looks up levels case-insensitively and ignores unknown levels" do
      expect(component.prepare("DEBUG", config_id: "flare-1")).to be true
      component.revert

      expect(component.prepare("off", config_id: "flare-2")).to be false
      expect(logger.level).to eq(::Logger::INFO)
    end

    it "reverts a stale capture without sleeping" do
      allow(Datadog::Core::Utils::Time).to receive(:get_time)
        .and_return(100, 100 + described_class::STALE_DURATION_SECONDS)

      component.prepare("debug", config_id: "flare-1")
      component.check_stale!

      expect(logger.level).to eq(::Logger::INFO)
    end
  end

  describe "#send_flare" do
    it "sends the expected form and includes logs and config in the zip" do
      component.prepare("debug", config_id: "flare-1")
      logger.debug("captured debug line")

      expect(transport).to receive(:send_flare) do |form|
        expect(form.keys).to contain_exactly("source", "case_id", "hostname", "email", "uuid", "flare_file")
        expect(form).to include(
          "source" => "tracer_ruby",
          "case_id" => "12345",
          "hostname" => "host",
          "email" => "user@example.com",
          "uuid" => "flare-uuid",
        )

        upload = form.fetch("flare_file")
        expect(upload.original_filename).to match(/\Atracer-ruby-12345-\d+-debug\.zip\z/)
        entries = read_entries(upload.io.string)
        expect(entries.fetch("tracer_ruby_#{Process.pid}.log")).to include("captured debug line")
        expect(JSON.parse(entries.fetch("tracer_config_#{Process.pid}.json"))).to include("configs")
        response
      end

      expect(
        component.send_flare(
          case_id: "12345",
          hostname: "host",
          email: "user@example.com",
          uuid: "flare-uuid",
        ),
      ).to be true
      expect(logger.level).to eq(::Logger::INFO)
      expect(output.string).not_to include("user@example.com")
    end

    it "uploads an empty log when capture was not prepared" do
      expect(transport).to receive(:send_flare) do |form|
        entries = read_entries(form.fetch("flare_file").io.string)
        expect(entries.fetch("tracer_ruby_#{Process.pid}.log")).to eq("")
        response
      end

      expect(
        component.send_flare(case_id: "12345", hostname: "host", email: "", uuid: "uuid"),
      ).to be true
    end

    it "returns false rather than raising when transport fails" do
      allow(transport).to receive(:send_flare).and_raise(IOError, "offline")

      expect(
        component.send_flare(case_id: "12345", hostname: "host", email: "", uuid: "uuid"),
      ).to be false
    end

    it "returns false for an unsuccessful HTTP response" do
      allow(transport).to receive(:send_flare)
        .and_return(double("response", internal_error?: false, code: 500))

      expect(
        component.send_flare(case_id: "12345", hostname: "host", email: "", uuid: "uuid"),
      ).to be false
    end

    it "returns false for an internal transport error" do
      allow(transport).to receive(:send_flare)
        .and_return(Datadog::Core::Transport::InternalErrorResponse.new(IOError.new("offline")))

      expect(
        component.send_flare(case_id: "12345", hostname: "host", email: "", uuid: "uuid"),
      ).to be false
    end
  end

  def read_entries(archive)
    entries = {}
    offset = 0

    while archive.byteslice(offset, 4).unpack1("V") == 0x04034b50
      header = archive.byteslice(offset, 30).unpack("VvvvvvVVVvv")
      name_length = header[9]
      extra_length = header[10]
      name = archive.byteslice(offset + 30, name_length)
      compressed = archive.byteslice(offset + 30 + name_length + extra_length, header[7])
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      entries[name] = inflater.inflate(compressed) + inflater.finish
      inflater.close
      offset += 30 + name_length + extra_length + header[7]
    end

    entries
  end
end
