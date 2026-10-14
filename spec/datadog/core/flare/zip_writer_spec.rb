# frozen_string_literal: true

require "spec_helper"
require "zlib"
require "datadog/core/flare/zip_writer"

RSpec.describe Datadog::Core::Flare::ZipWriter do
  subject(:archive) do
    described_class.build(
      [
        ["logs.txt", "flare logs\n"],
        ["empty.txt", ""],
      ],
    )
  end

  it "writes local entries that inflate with the expected contents and CRC" do
    eocd_offset = archive.rindex("PK\x05\x06".b)
    expect(archive.byteslice(eocd_offset + 10, 2).unpack1("v")).to eq(2)

    expected = {"logs.txt" => "flare logs\n", "empty.txt" => ""}
    offset = 0
    2.times do
      header = archive.byteslice(offset, 30).unpack("VvvvvvVVVvv")
      name_length = header[9]
      extra_length = header[10]
      name = archive.byteslice(offset + 30, name_length)
      compressed = archive.byteslice(offset + 30 + name_length + extra_length, header[7])
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      content = inflater.inflate(compressed) + inflater.finish
      inflater.close

      expect(content).to eq(expected.fetch(name))
      expect(header[6]).to eq(Zlib.crc32(content))
      offset += 30 + name_length + extra_length + header[7]
    end
  end
end
