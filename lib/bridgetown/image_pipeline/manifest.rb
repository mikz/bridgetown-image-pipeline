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
        invalidate_conflicts(symbolized[:variants].map { |variant| variant[:path] }, except: cache_key)
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

      def clear
        @entries.clear
      end

      def find_by_src(src, preset: :default)
        find(src, preset)
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

      def invalidate_conflicts(paths, except:)
        conflicting = paths.to_h { |path| [path, true] }
        Dir.glob(File.join(@cache_dir, "*.manifest.json")).each do |path|
          next if path == cache_file(except)

          entry = deep_symbolize(JSON.parse(File.read(path)))
          FileUtils.rm_f(path) if entry[:variants].any? { |variant| conflicting[variant[:path]] }
        rescue JSON::ParserError
          FileUtils.rm_f(path)
        end
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
