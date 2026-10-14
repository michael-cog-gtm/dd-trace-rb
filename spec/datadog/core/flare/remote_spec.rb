# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "datadog/core/flare/remote"

RSpec.describe Datadog::Core::Flare::Remote do
  let(:component) do
    double("flare component", check_stale!: nil, prepare: true, revert: nil, send_flare: true)
  end
  let(:components) { double("components", flare: component) }
  let(:logger) { Datadog::Core::Logger.new(StringIO.new) }

  before do
    allow(Datadog).to receive(:send)
      .with(:components, allow_initialization: false)
      .and_return(components)
    allow(components).to receive(:logger).and_return(logger)
  end

  def build_change(product:, config_id:, data: "{}", type: :insert)
    path = Datadog::Core::Remote::Configuration::Path.parse(
      "datadog/123/#{product}/#{config_id}/config",
    )
    content = Datadog::Core::Remote::Configuration::Content.parse(
      {path: path.to_s, content: data},
    )

    case type
    when :insert
      Datadog::Core::Remote::Configuration::Repository::Change::Inserted.new(path, content)
    when :update
      previous = Datadog::Core::Remote::Configuration::Content.parse(
        {path: path.to_s, content: "{}"},
      )
      Datadog::Core::Remote::Configuration::Repository::Change::Updated.new(path, content, previous)
    when :delete
      previous = Datadog::Core::Remote::Configuration::Content.parse(
        {path: path.to_s, content: "{}"},
      )
      Datadog::Core::Remote::Configuration::Repository::Change::Deleted.new(path, previous)
    end
  end

  def process(change_or_changes)
    described_class.process_changes(Array(change_or_changes))
  end

  it "acknowledges a log-level config" do
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", data: '{"config":{"log_level":"debug"}}')

    process(change)

    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
    expect(component).to have_received(:prepare).with("debug", config_id: "flare-1")
  end

  it "acknowledges configuration_order without parsing it" do
    change = build_change(product: "AGENT_CONFIG", config_id: "configuration_order", data: "not json")

    process(change)

    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "reverts a config with an empty payload" do
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1")

    process(change)

    expect(component).to have_received(:revert).with(config_id: "flare-1")
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "sends tracer flare tasks" do
    change = build_change(
      product: "AGENT_TASK",
      config_id: "task-1",
      data: '{"task_type":"tracer_flare","uuid":"task-uuid","args":{"case_id":"12345","hostname":"host","user_handle":"person@example.com"}}',
    )

    process(change)

    expect(component).to have_received(:send_flare).with(
      case_id: "12345",
      hostname: "host",
      email: "person@example.com",
      uuid: "task-uuid",
    )
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "acknowledges other task types without uploading" do
    change = build_change(
      product: "AGENT_TASK",
      config_id: "task-1",
      data: '{"task_type":"flare","uuid":"task-uuid","args":{"case_id":"12345","hostname":"host","user_handle":"person@example.com"}}',
    )

    process(change)

    expect(component).not_to have_received(:send_flare)
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "acknowledges a task with an invalid case id without uploading" do
    change = build_change(
      product: "AGENT_TASK",
      config_id: "task-1",
      data: '{"task_type":"tracer_flare","uuid":"task-uuid","args":{"case_id":"0","hostname":"host","user_handle":"person@example.com"}}',
    )

    process(change)

    expect(component).not_to have_received(:send_flare)
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "acknowledges a task with only a top-level case id without uploading" do
    change = build_change(
      product: "AGENT_TASK",
      config_id: "task-1",
      data: '{"task_type":"tracer_flare","case_id":"12345","uuid":"task-uuid","args":{"hostname":"host","user_handle":"person@example.com"}}',
    )

    process(change)

    expect(component).not_to have_received(:send_flare)
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "marks invalid JSON as errored" do
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", data: "invalid json")

    process(change)

    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ERROR)
  end

  it "marks a non-object JSON payload as errored" do
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", data: "[]")

    process(change)

    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ERROR)
  end

  it "processes config changes before tasks in the same change set" do
    task = build_change(
      product: "AGENT_TASK",
      config_id: "task-1",
      data: '{"task_type":"tracer_flare","uuid":"task-uuid","args":{"case_id":"12345","hostname":"host","user_handle":"person@example.com"}}',
    )
    config = build_change(
      product: "AGENT_CONFIG",
      config_id: "flare-1",
      data: '{"config":{"log_level":"debug"}}',
    )
    expect(component).to receive(:prepare).ordered
    expect(component).to receive(:send_flare).ordered

    process([task, config])
  end

  it "reverts the active config when it is deleted" do
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", type: :delete)

    process(change)

    expect(component).to have_received(:revert).with(config_id: "flare-1")
    expect(change.previous.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::UNACKNOWLEDGED)
  end

  it "acknowledges valid content when the component is absent" do
    allow(components).to receive(:flare).and_return(nil)
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", data: "{}")

    process(change)

    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end

  it "continues processing changes when stale-checking raises" do
    allow(component).to receive(:check_stale!).and_raise(RuntimeError, "stale-check failed")
    change = build_change(product: "AGENT_CONFIG", config_id: "flare-1", data: "{}")

    expect { process(change) }.not_to raise_error
    expect(change.content.apply_state).to eq(Datadog::Core::Remote::Configuration::Content::ApplyState::ACKNOWLEDGED)
  end
end
