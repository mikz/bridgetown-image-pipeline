# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "uri"
require_relative "manifest"
require_relative "processor"
require_relative "version"

module Bridgetown
  module ImagePipeline
    class Pipeline
      def initialize(config:, root_dir:, output_root:, cache_root:)
        @config = config
        @root_dir = File.realpath(root_dir)
        @output_root = output_root
        @manifest = Manifest.new(cache_dir: cache_root)
        @derivative_root = File.join(cache_root, "files")
        @processor = Processor.new(config: config, output_root: @derivative_root)
        @sources = {}
        @resolved_entries = {}
      end

      def refresh
        patterns = @config.source_globs.map { |glob| File.join(@root_dir, glob) }
        excludes = @config.exclude.map { |glob| File.join(@root_dir, glob) }
        paths = patterns.flat_map { |pattern| Dir.glob(pattern) }
        paths.reject! do |path|
          excludes.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end
        @sources = paths.uniq.sort.filter_map { |path| canonical_source(path) }.to_h
        @resolved_entries.clear
        self
      end

      def resolve(src, preset: nil)
        normalized_src = normalize_src(src)
        return unless normalized_src

        source_path = @sources[normalized_src]
        return unless source_path

        preset_name = (preset || @config.default_preset).to_sym
        preset_config = @config.preset(preset_name)
        resolved_key = [normalized_src, preset_name]
        existing = @resolved_entries[resolved_key]
        return materialize(existing) if existing && derivatives_cached?(existing)

        key = cache_key(source_path, preset_name, preset_config)
        cached = @manifest.fetch_cached(key)
        if cached && derivatives_cached?(cached)
          @manifest.register_cached(normalized_src, preset_name, cached)
          @resolved_entries[resolved_key] = cached
          return materialize(cached)
        end

        result = @processor.process(
          source_path,
          source_id: normalized_src.delete_prefix("/"),
          preset_name: preset_name,
          preset: preset_config
        )
        @manifest.put(normalized_src, preset_name, result, cache_key: key)
        @resolved_entries[resolved_key] = result
        materialize(result)
      end

      private

      def normalize_src(src)
        value = src.to_s.split(/[?#]/, 2).first
        return if value.empty? || value.start_with?("//") || value.match?(/\A[a-z][a-z0-9+.-]*:/i)

        value = URI::RFC2396_PARSER.unescape(value)
        return unless value.start_with?("/")
        return if value.split("/").include?("..")

        value
      rescue URI::InvalidURIError
        nil
      end

      def public_src(absolute_path)
        relative = absolute_path.delete_prefix("#{@root_dir}/")
        "/#{relative.sub(%r{\Asrc/}, "")}"
      end

      def canonical_source(path)
        return unless File.file?(path)

        canonical = File.realpath(path)
        return unless canonical == @root_dir || canonical.start_with?("#{@root_dir}/")

        [public_src(path), canonical]
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def cache_key(source_path, preset_name, preset)
        digest = Digest::SHA1.new
        digest.update(File.binread(source_path))
        digest.update(Bridgetown::ImagePipeline::VERSION)
        digest.update(JSON.generate(
                        preset: preset_name,
                        config: preset,
                        formats: @config.formats,
                        output_dir: @config.output_dir,
                        quality: @config.quality
                      ))
        digest.hexdigest
      end

      def derivatives_cached?(entry)
        entry[:variants].all? do |variant|
          File.exist?(File.join(@derivative_root, variant[:path].delete_prefix("/")))
        end
      end

      def materialize(entry)
        entry[:variants].each do |variant|
          relative_path = variant[:path].delete_prefix("/")
          cached_path = File.join(@derivative_root, relative_path)
          output_path = File.join(@output_root, relative_path)
          FileUtils.mkdir_p(File.dirname(output_path))
          FileUtils.cp(cached_path, output_path)
        end
        entry
      end
    end
  end
end
