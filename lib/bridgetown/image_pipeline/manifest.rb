# frozen_string_literal: true

require "json"
require "fileutils"

module Bridgetown
  module ImagePipeline
    class Manifest
      def initialize(cache_dir:)
        @cache_dir = cache_dir
        FileUtils.mkdir_p(@cache_dir)
        @entries = {} # [public source path, preset] => entry hash
      end

      def put(src, preset, entry, cache_key:)
        symbolized = deep_symbolize(entry)
        @entries[[src, preset.to_sym]] = symbolized
        File.write(cache_file(cache_key), JSON.generate(symbolized))
        symbolized
      end

      def fetch_cached(cache_key)
        path = cache_file(cache_key)
        return nil unless File.exist?(path)

        deep_symbolize(JSON.parse(File.read(path)))
      end

      def register_cached(src, preset, entry)
        @entries[[src, preset.to_sym]] = entry
      end

      def find(src, preset)
        @entries[[src, preset.to_sym]]
      end

      def variants_by_width(src, preset)
        entry = find(src, preset)
        return {} unless entry

        entry[:variants].each_with_object({}) do |v, out|
          (out[v[:width]] ||= {})[v[:format]] = v[:path]
        end
      end

      def all
        @entries.dup
      end

      private

      def cache_file(cache_key)
        File.join(@cache_dir, "#{cache_key}.manifest.json")
      end

      def deep_symbolize(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), out| out[k.to_sym] = deep_symbolize(v) }
        when Array then obj.map { |v| deep_symbolize(v) }
        when String
          %w[avif webp jpeg jpg png].include?(obj) ? obj.to_sym : obj
        else obj
        end
      end
    end
  end
end
