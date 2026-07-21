# frozen_string_literal: true

require "cgi/escape"
require_relative "bg_image_set"

module Bridgetown
  module ImagePipeline
    class Helpers
      def initialize(pipeline:, config:)
        @pipeline = pipeline
        @config   = config
      end

      def picture_tag(src, alt: "", sizes: nil, priority: false, preset: nil, **attrs)
        entry = @pipeline.resolve(src, preset: preset)
        return fallback_img(src, alt: alt, sizes: sizes, priority: priority, attrs: attrs) unless entry

        sources_html = picture_sources(entry, sizes: sizes)
        img_html     = img_for_entry(entry, src: src, alt: alt, sizes: sizes, priority: priority, attrs: attrs)
        "<picture>#{sources_html}#{img_html}</picture>"
      end

      def bg_image_class(src, class_suffix: nil)
        slug = File.basename(src, ".*").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        suffix = class_suffix ? "-#{class_suffix.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")}" : ""
        "bg-img-#{slug}#{suffix}"
      end

      def bg_image_block(src, breakpoint_only: nil, class_suffix: nil, preset: nil)
        class_name = bg_image_class(src, class_suffix: class_suffix)
        entry = @pipeline.resolve(src, preset: preset)
        variants = variants_by_width(entry)

        if variants.empty?
          warn "[bridgetown-image-pipeline] no manifest entry for #{src}; bg_image_block falling back to url(#{src})"
          body = ".#{class_name}{background-image:#{BgImageSet.css_url(src)}}"
          body = "@media (min-width:#{breakpoint_only}px){#{body}}" if breakpoint_only
          return "<style>#{body}</style>"
        end

        css = BgImageSet.css(
          class_name: class_name,
          variants: variants,
          breakpoints: @config.breakpoints,
          default_width: @config.default_width,
          breakpoint_only: breakpoint_only
        )
        "<style>#{css}</style>"
      end

      private

      def variants_by_width(entry)
        return {} unless entry

        entry[:variants].each_with_object({}) do |variant, grouped|
          (grouped[variant[:width]] ||= {})[variant[:format]] = variant[:path]
        end
      end

      def picture_sources(entry, sizes:)
        @config.formats.map do |fmt|
          variants = entry[:variants].select { |v| v[:format] == fmt }
          next nil if variants.empty?

          srcset = variants.map { |v| "#{v[:path]} #{v[:width]}w" }.join(", ")
          attrs = { type: "image/#{fmt}", srcset: srcset }
          attrs[:sizes] = sizes if sizes
          %(<source #{render_attrs(attrs)}>)
        end.compact.join
      end

      def img_for_entry(entry, src:, alt:, sizes:, priority:, attrs:)
        fallback_variants = entry[:variants].select { |v| v[:format] != :avif && v[:format] != :webp }
        default = fallback_variants.find { |v| v[:width] == middle_width(fallback_variants) } || fallback_variants.last
        srcset = fallback_variants.map { |v| "#{v[:path]} #{v[:width]}w" }.join(", ")
        intrinsic_width, intrinsic_height = intrinsic_dimensions(entry, default, attrs)

        merged = {
          src: default ? default[:path] : src,
          srcset: srcset.empty? ? nil : srcset,
          sizes: sizes,
          width: intrinsic_width,
          height: intrinsic_height,
          alt: alt,
          loading: priority ? "eager" : "lazy",
          decoding: "async",
          fetchpriority: priority ? "high" : nil
        }.merge(attrs)

        "<img #{render_attrs(merged)}>"
      end

      def fallback_img(src, alt:, sizes:, priority:, attrs:)
        raise MissingSourceError, "image not in pipeline manifest: #{src}" if @config.fail_on_missing

        warn "[bridgetown-image-pipeline] no manifest entry for #{src}; rendering plain <img>"
        merged = {
          src: src, alt: alt, sizes: sizes,
          loading: priority ? "eager" : "lazy",
          decoding: "async",
          fetchpriority: priority ? "high" : nil
        }.merge(attrs)
        "<img #{render_attrs(merged)}>"
      end

      def middle_width(variants)
        ws = variants.map { |v| v[:width] }.sort
        ws[ws.length / 2]
      end

      def scaled_height(image, width)
        (image[:height] * width.to_f / image[:width]).round
      end

      def intrinsic_dimensions(entry, default, attrs)
        width = attrs.fetch(:width) { default ? default[:width] : entry[:width] }
        height = attrs.fetch(:height) { scaled_height(default || entry, width) }
        [width, height]
      end

      def render_attrs(attrs)
        attrs.compact.map do |k, v|
          key = k.to_s.tr("_", "-")
          %(#{key}="#{CGI.escapeHTML(v.to_s)}")
        end.join(" ")
      end
    end
  end
end
