# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "logger"
require "datadog/core/flare/log_capture"

RSpec.describe Datadog::Core::Flare::LogCapture do
  let(:output) { StringIO.new }
  let(:logger) { Datadog::Core::Logger.new(output) }

  subject(:capture) { described_class.new(level: ::Logger::DEBUG) }

  it "captures message, block, and progname-only logging" do
    logger.level = ::Logger::DEBUG
    capture.attach(logger)
    block_calls = 0

    logger.add(::Logger::DEBUG, "message form")
    logger.add(::Logger::DEBUG) do
      block_calls += 1
      "block form"
    end
    logger.add(::Logger::DEBUG, nil, "progname form")

    expect(block_calls).to eq(1)
    expect(capture.contents).to include("message form", "block form", "progname form")
  ensure
    capture.detach(logger)
  end

  it "does not capture messages below its configured level" do
    capture = described_class.new(level: ::Logger::WARN)
    capture.attach(logger)

    logger.info("below capture level")

    expect(capture.contents).to eq("")
  ensure
    capture.detach(logger)
  end

  it "does not evaluate messages below the logger level" do
    logger.level = ::Logger::DEBUG
    capture.attach(logger)
    logger.level = ::Logger::WARN

    expect { logger.debug { raise "evaluated" } }.not_to raise_error
    logger.warn("x")

    expect(capture.contents).to include("x")
  ensure
    capture.detach(logger)
  end

  it "preserves the logger output for a captured message" do
    baseline_output = StringIO.new
    baseline_logger = Datadog::Core::Logger.new(baseline_output)
    baseline_logger.level = ::Logger::DEBUG
    baseline_logger.debug("same message")

    capture.attach(logger)
    logger.level = ::Logger::DEBUG
    logger.debug("same message")

    expect(output.string).to include("same message")
    expect(output.string.split("same message").last).to eq(baseline_output.string.split("same message").last)
    expect(output.string.scan("same message").length).to eq(baseline_output.string.scan("same message").length)
  ensure
    capture.detach(logger)
  end

  it "preserves logger output when a message cannot be inspected" do
    message = Class.new do
      def inspect
        raise "inspection failed"
      end

      def to_s
        "rendered message"
      end
    end.new
    logger.level = ::Logger::DEBUG
    capture.attach(logger)

    expect { logger.add(::Logger::DEBUG, message) }.not_to raise_error
    expect(output.string).to include("rendered message")
    expect(capture.contents).to eq("")
  ensure
    capture.detach(logger)
  end

  it "removes the singleton methods on detach" do
    expect(capture.attach(logger)).to be true

    capture.detach(logger)

    expect(logger.singleton_methods(false)).not_to include(:add, :log)
  end

  it "adds one truncation marker after reaching the byte limit" do
    capture = described_class.new(level: ::Logger::DEBUG, max_bytes: 1)
    logger.level = ::Logger::DEBUG
    capture.attach(logger)

    logger.debug("first")
    logger.debug("second")

    expect(capture.contents.scan(described_class::TRUNCATED_MESSAGE).length).to eq(1)
    expect(capture.contents).not_to include("first", "second")
  ensure
    capture.detach(logger)
  end

  it "does not replace a logger's existing singleton add method" do
    logger.define_singleton_method(:add) { |*_args, &_block| :original }

    expect(capture.attach(logger)).to be false
    expect(logger.add(::Logger::DEBUG, "message")).to eq(:original)
    expect(capture.contents).to eq("")
  end

  it "captures messages from a standard logger" do
    stdlib_logger = ::Logger.new(StringIO.new)
    stdlib_logger.level = ::Logger::DEBUG
    capture.attach(stdlib_logger)

    stdlib_logger.debug("stdlib message")

    expect(capture.contents).to include("stdlib message")
  ensure
    capture.detach(stdlib_logger)
  end
end
