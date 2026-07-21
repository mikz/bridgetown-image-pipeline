# frozen_string_literal: true

require_relative "config"
require_relative "pipeline"
require_relative "inspector"

module Bridgetown
  module ImagePipeline
    class Builder < Bridgetown::Builder
      attr_reader :pipeline, :config

      # Bridgetown 2.x calls .new(name, site) on registered builders; earlier
      # docs assumed .new(site). Accept either calling convention.
      class << self
        attr_accessor :pending_config
      end

      def initialize(*args, cache_root: nil)
        site = args.last
        super(*args)
        @site        = site
        @config      = self.class.pending_config || Config.from
        cache_root ||= File.join(site.root_dir, ".image-pipeline-cache")
        @output_root = site.in_dest_dir
        @pipeline    = Pipeline.new(
          config: @config,
          root_dir: site.root_dir,
          output_root: @output_root,
          cache_root: cache_root
        )
      end

      def build
        hook(:site, :pre_render) { @pipeline.refresh }
        attach_to_site!
        register_auto_rewrite_hooks! if @config.auto_rewrite
      end

      def register_auto_rewrite_hooks!
        inspector = Inspector.new(pipeline: @pipeline, config: @config)
        site_to_match = @site
        rewriter = lambda do |obj|
          return unless obj.site.equal?(site_to_match)
          return unless html_output?(obj)

          obj.output = inspector.rewrite(obj.output.to_s)
        end
        Bridgetown::Hooks.register_one(:resources,       :post_render, reloadable: false, &rewriter)
        Bridgetown::Hooks.register_one(:generated_pages, :post_render, reloadable: false, &rewriter)
      end

      def html_output?(obj)
        return false unless obj.respond_to?(:output_ext)

        obj.output_ext.to_s.downcase == ".html"
      end

      def attach_to_site!
        site = @site
        pipeline = @pipeline
        config   = @config
        site.define_singleton_method(:image_pipeline) { pipeline }
        site.define_singleton_method(:image_pipeline_config) { config }
      end
    end
  end
end
