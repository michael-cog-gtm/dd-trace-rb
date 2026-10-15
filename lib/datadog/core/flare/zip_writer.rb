# frozen_string_literal: true

require "zlib"
require_relative "../utils/time"

module Datadog
  module Core
    module Flare
      module ZipWriter
        class << self
          def build(entries)
            archive = String.new(encoding: ::Encoding::BINARY)
            central_directory = String.new(encoding: ::Encoding::BINARY)
            now = Core::Utils::Time.now
            dos_time = (now.hour << 11) | (now.min << 5) | (now.sec / 2)
            dos_date = ((now.year - 1980) << 9) | (now.month << 5) | now.day

            entries.each do |name, content|
              name = name.encode(::Encoding::US_ASCII)
              content = content.to_s.b
              compressed = deflate(content)
              crc = Zlib.crc32(content)
              offset = archive.bytesize

              archive << [
                0x04034b50, 20, 0, 8, dos_time, dos_date, crc,
                compressed.bytesize, content.bytesize, name.bytesize, 0,
              ].pack("VvvvvvVVVvv")
              archive << name << compressed

              central_directory << [
                0x02014b50, 20, 20, 0, 8, dos_time, dos_date, crc,
                compressed.bytesize, content.bytesize, name.bytesize, 0, 0,
                0, 0, 0, offset,
              ].pack("VvvvvvvVVVvvvvvVV")
              central_directory << name
            end

            central_offset = archive.bytesize
            archive << central_directory
            archive << [
              0x06054b50, 0, 0, entries.length, entries.length,
              central_directory.bytesize, central_offset, 0,
            ].pack("VvvvvVVv")
            archive
          end

          private

          def deflate(content)
            deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
            compressed = deflater.deflate(content, Zlib::FINISH)
            deflater.close
            compressed
          end
        end
      end
    end
  end
end
