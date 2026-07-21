# frozen_string_literal: true

require "image_processing/vips"
require "fileutils"

module Bridgetown
  module ImagePipeline
    class Processor
      def initialize(config:, output_root:)
        @config = config
        @output_root = output_root
      end

      def process(source_path, source_id:, preset_name:, preset:)
        image = Vips::Image.new_from_buffer(File.binread(source_path), "").autorot
        source_width  = image.width
        source_height = image.height
        original_fmt = File.extname(source_path).downcase.delete(".").sub("jpeg", "jpg").to_sym
        variants = build_variants(image,
                                  source_id: source_id,
                                  preset_name: preset_name,
                                  preset: preset,
                                  original_fmt: original_fmt,
                                  source_size: [source_width, source_height])

        { width: source_width, height: source_height, variants: variants }
      end

      private

      def build_variants(source_image, source_id:, preset_name:, preset:, original_fmt:, source_size:)
        source_width, source_height = source_size
        variants = []
        requested_variants(preset).each do |dimensions|
          target_width, target_height = dimensions
          next if target_width > source_width
          next if target_height && target_height > source_height

          formats = @config.formats.dup
          formats << original_fmt unless formats.include?(original_fmt)
          formats.each do |format|
            variants << build_variant(source_image,
                                      source_id: source_id,
                                      preset_name: preset_name,
                                      preset: preset,
                                      dimensions: dimensions,
                                      format: format)
          end
        end
        variants
      end

      def requested_variants(preset)
        return preset[:widths].map { |width| [width, nil] } if preset[:fit] == :limit

        preset[:sizes]
      end

      def build_variant(source_image, source_id:, preset_name:, preset:, dimensions:, format:)
        target_width, target_height = dimensions
        label = target_height ? "#{target_width}x#{target_height}" : "#{target_width}w"
        filename = "#{label}.#{format == :jpeg ? "jpg" : format}"
        output_path = File.join(source_id, preset_name.to_s, filename)
        relative_path = File.join("/", @config.output_dir, output_path)
        absolute_path = File.join(@output_root, @config.output_dir, output_path)
        FileUtils.mkdir_p(File.dirname(absolute_path))

        saver_format = format == :jpg ? :jpeg : format
        quality = @config.quality[saver_format] || @config.quality[format]

        pipeline = ImageProcessing::Vips.source(source_image)
        pipeline = if preset[:fit] == :fill
                     pipeline.resize_to_fill(target_width, target_height)
                   else
                     pipeline.resize_to_limit(target_width, nil)
                   end
        pipeline
          .convert(saver_format.to_s)
          .saver(quality: quality)
          .call(destination: absolute_path)

        output = Vips::Image.new_from_file(absolute_path)

        { path: relative_path, width: output.width, height: output.height, format: saver_format }
      end
    end
  end
end
