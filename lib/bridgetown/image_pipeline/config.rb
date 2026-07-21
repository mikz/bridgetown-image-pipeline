# frozen_string_literal: true

module Bridgetown
  module ImagePipeline
    Config = Struct.new(
      :source_globs, :exclude, :widths, :formats, :output_dir,
      :quality, :auto_rewrite, :fail_on_missing, :breakpoints, :default_width,
      :presets, :default_preset,
      keyword_init: true
    ) do
      DEFAULTS = {
        source_globs: ["src/images/**/*.{jpg,jpeg,png}"],
        exclude: [],
        widths: [400, 600, 800, 1200, 1600],
        formats: %i[avif webp],
        output_dir: "_bridgetown/image_pipeline",
        quality: { avif: 65, webp: 88, jpeg: 88 },
        auto_rewrite: false,
        fail_on_missing: false,
        breakpoints: { 640 => 400, 768 => 600, 1024 => 800, 1280 => 1200 },
        default_width: 1600,
        presets: nil,
        default_preset: :default
      }.freeze

      # Build a Config from initializer kwargs. Unknown keys raise.
      def self.from(**overrides)
        merged = DEFAULTS.merge(overrides)
        merged[:formats] = Array(merged[:formats]).map(&:to_sym)
        quality = (merged[:quality] || {}).to_h.transform_keys(&:to_sym)
        merged[:quality] = DEFAULTS[:quality].merge(quality)
        merged[:default_preset] = merged[:default_preset].to_sym
        merged[:presets] = normalize_presets(merged[:presets] || {
                                               merged[:default_preset] => { widths: merged[:widths], fit: :limit }
                                             })
        unless merged[:presets].key?(merged[:default_preset])
          raise ArgumentError, "unknown default image preset: #{merged[:default_preset]}"
        end

        new(**merged)
      end

      def preset(name = default_preset)
        presets.fetch((name || default_preset).to_sym) do
          raise ArgumentError, "unknown image preset: #{name}"
        end
      end

      def self.normalize_presets(presets)
        presets.to_h.each_with_object({}) do |(name, value), out|
          out[name.to_sym] = normalize_preset(value).freeze
        end.freeze
      end

      def self.normalize_preset(value)
        preset = value.to_h.transform_keys(&:to_sym)
        widths = Array(preset[:widths]).map { |width| positive_integer(width, "width") }
        sizes = normalize_sizes(preset[:sizes])
        raise ArgumentError, "image preset must define exactly one of widths or sizes" if widths.empty? == sizes.empty?

        fit = (preset[:fit] || (sizes.empty? ? :limit : :fill)).to_sym
        raise ArgumentError, "unsupported image preset fit: #{fit}" unless %i[limit fill].include?(fit)

        position = (preset[:position] || :centre).to_sym
        raise ArgumentError, "unsupported image preset position: #{position}" unless position == :centre

        preset.merge(widths: widths.uniq.sort, sizes: sizes.uniq.sort, fit: fit, position: position)
      end

      def self.normalize_sizes(values)
        Array(values).map do |size|
          raise ArgumentError, "image preset size must be [width, height]" unless size.is_a?(Array) && size.length == 2

          size.map { |dimension| positive_integer(dimension, "size") }
        end
      end

      def self.positive_integer(value, label)
        integer = Integer(value)
        raise ArgumentError, "image preset #{label} must be positive" unless integer.positive?

        integer
      rescue TypeError, ArgumentError
        raise ArgumentError, "image preset #{label} must be a positive integer"
      end
      private_class_method :normalize_presets, :normalize_preset, :normalize_sizes, :positive_integer
    end
  end
end
