# frozen_string_literal: true

require "nokogiri"

module Bridgetown
  module ImagePipeline
    class Inspector
      def initialize(pipeline:, config:)
        @pipeline = pipeline
        @config   = config
      end

      def rewrite(html)
        return html unless @config.auto_rewrite

        doc = Nokogiri::HTML5.parse(html)
        Inspector.find_imgs(doc).each { |img| process_img(img, doc) }
        doc.to_html
      end

      # Nokogiri 1.19 + HTML5 docs translate `css("img")` to the xpath
      # `//*:img`, which libxml on Linux CI rejects with
      # "Invalid expression". Use local-name() to bypass the HTML5
      # namespace handling entirely.
      def self.find_imgs(doc)
        doc.xpath(".//*[local-name()='img']")
      end

      def process_img(img, doc)
        return unless eligible?(img)

        preset = img["data-image-preset"] || @config.default_preset
        img.remove_attribute("data-image-preset")
        entry = @pipeline.resolve(img["src"], preset: preset)
        return unless entry

        ensure_dimensions(img, entry)
        img["loading"] ||= "lazy"
        img["decoding"] ||= "async"
        ensure_img_srcset(img, entry)

        picture = build_picture(img, entry, doc)
        img.replace(picture).tap { picture.add_child(img) }
      end

      private

      def eligible?(img)
        return false if img.parent&.name == "picture"
        return false if img.has_attribute?("data-no-pipeline")
        return false if img.has_attribute?("srcset")

        true
      end

      def build_picture(img, entry, doc)
        picture = Nokogiri::XML::Node.new("picture", doc)
        @config.formats.each do |fmt|
          variants = entry[:variants].select { |v| v[:format] == fmt }
          next if variants.empty?

          source = Nokogiri::XML::Node.new("source", doc)
          source["type"]   = "image/#{fmt}"
          source["srcset"] = variants.map { |v| "#{v[:path]} #{v[:width]}w" }.join(", ")
          source["sizes"]  = img["sizes"] if img["sizes"]
          picture.add_child(source)
        end
        picture
      end

      def ensure_dimensions(img, entry)
        img["width"]  ||= entry[:width].to_s
        img["height"] ||= entry[:height].to_s
      end

      def ensure_img_srcset(img, entry)
        return if img["srcset"]

        fallback = entry[:variants].reject { |v| %i[avif webp].include?(v[:format]) }
        return if fallback.empty?

        img["srcset"] = fallback.map { |v| "#{v[:path]} #{v[:width]}w" }.join(", ")
        img["sizes"] ||= @config.preset(@config.default_preset)[:default_sizes] || "100vw"
        smallest = fallback.min_by { |v| v[:width] }
        img["src"] = smallest[:path] if smallest
      end
    end
  end
end
