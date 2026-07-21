# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class FakePipeline
  def initialize(entries = {})
    @entries = entries
  end

  def resolve(src, preset: nil)
    @entries[[src, (preset || :default).to_sym]]
  end
end

module ImagePipelineTestData
  module_function

  def entry
    {
      width: 1200,
      height: 600,
      variants: [
        { path: "/generated/known-400.webp", width: 400, height: 200, format: :webp },
        { path: "/generated/known-400.jpg", width: 400, height: 200, format: :jpeg },
        { path: "/generated/known-1200.webp", width: 1200, height: 600, format: :webp },
        { path: "/generated/known-1200.jpg", width: 1200, height: 600, format: :jpeg }
      ]
    }
  end
end

class ConfigTest < Minitest::Test
  def test_builds_default_limit_preset_from_legacy_widths
    config = Bridgetown::ImagePipeline::Config.from(
      widths: [320, 960],
      formats: [:webp],
      quality: {"webp" => 85}
    )

    assert_equal :default, config.default_preset
    assert_equal [320, 960], config.preset(:default)[:widths]
    assert_equal :limit, config.preset(:default)[:fit]
    assert_equal [:webp], config.formats
    assert_equal 85, config.quality[:webp]
    refute config.quality.key?("webp")
  end

  def test_normalizes_named_limit_and_fill_presets
    config = Bridgetown::ImagePipeline::Config.from(
      default_preset: :content,
      presets: {
        content: { widths: [760, 480], fit: :limit, default_sizes: "90vw" },
        avatar: { sizes: [[192, 192], [96, 96]], fit: :fill, position: :centre }
      }
    )

    assert_equal [480, 760], config.preset(:content)[:widths]
    assert_equal "90vw", config.preset(:content)[:default_sizes]
    assert_equal [[96, 96], [192, 192]], config.preset(:avatar)[:sizes]
    assert_equal :centre, config.preset(:avatar)[:position]
  end

  def test_rejects_ambiguous_or_unknown_presets
    assert_raises(ArgumentError) do
      Bridgetown::ImagePipeline::Config.from(presets: { invalid: { widths: [100], sizes: [[100, 100]] } })
    end
    assert_raises(ArgumentError) do
      Bridgetown::ImagePipeline::Config.from(default_preset: :missing, presets: { content: { widths: [100] } })
    end
  end
end

class ManifestTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("image_pipeline_manifest")
    @manifest = Bridgetown::ImagePipeline::Manifest.new(cache_dir: @tmp)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_entries_are_preset_aware_and_cache_round_trips
    entry = ImagePipelineTestData.entry
    @manifest.put("/images/known.jpg", :content, entry, cache_key: "content")
    @manifest.put("/images/known.jpg", :avatar, entry.merge(width: 96), cache_key: "avatar")

    assert_equal 1200, @manifest.find("/images/known.jpg", :content)[:width]
    assert_equal 96, @manifest.find("/images/known.jpg", :avatar)[:width]
    assert_equal 1200, @manifest.fetch_cached("content")[:width]
    assert_equal :webp, @manifest.fetch_cached("content")[:variants].first[:format]
  end
end

class ProcessorTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("image_pipeline_processor")
    @source = File.expand_path("fixtures/test-image.jpg", __dir__)
    @config = Bridgetown::ImagePipeline::Config.from(
      formats: [:webp],
      output_dir: "generated",
      quality: { webp: 82, jpeg: 85 }
    )
    @processor = Bridgetown::ImagePipeline::Processor.new(config: @config, output_root: @tmp)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_limit_generates_modern_and_source_format_without_upscaling
    result = @processor.process(
      @source,
      source_id: "images/photo-jpg-abc123",
      preset_name: :content,
      preset: { widths: [400, 2400], sizes: [], fit: :limit, position: :centre }
    )

    assert_equal [400], result[:variants].map { |variant| variant[:width] }.uniq
    assert_equal %i[jpeg webp], result[:variants].map { |variant| variant[:format] }.sort
    assert(result[:variants].all? { |variant| variant[:height] == 200 })
    assert(result[:variants].all? { |variant| File.exist?(File.join(@tmp, variant[:path])) })
  end

  def test_fill_generates_exact_square_and_omits_too_large_variant
    result = @processor.process(
      @source,
      source_id: "images/photo-jpg-abc123",
      preset_name: :avatar,
      preset: { widths: [], sizes: [[96, 96], [2400, 2400]], fit: :fill, position: :centre }
    )

    assert_equal [[96, 96]], result[:variants].map { |variant| [variant[:width], variant[:height]] }.uniq
    assert(result[:variants].all? { |variant| variant[:path].include?("avatar-96x96") })
  end
end

class PipelineTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("image_pipeline")
    FileUtils.mkdir_p(File.join(@tmp, "src", "img", "nested"))
    FileUtils.cp(File.expand_path("fixtures/test-image.jpg", __dir__), File.join(@tmp, "src", "img", "same.jpg"))
    FileUtils.cp(File.expand_path("fixtures/test-image.webp", __dir__), File.join(@tmp, "src", "img", "nested", "same.webp"))
    @output = File.join(@tmp, "output")
    @config = Bridgetown::ImagePipeline::Config.from(
      source_globs: ["src/img/**/*.{jpg,webp}"],
      formats: [:webp],
      output_dir: "generated",
      default_preset: :content,
      presets: {
        content: { widths: [400], fit: :limit },
        avatar: { sizes: [[96, 96]], fit: :fill }
      }
    )
    @pipeline = Bridgetown::ImagePipeline::Pipeline.new(
      config: @config,
      root_dir: @tmp,
      output_root: @output,
      cache_root: File.join(@tmp, "cache")
    ).refresh
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_resolve_is_lazy_and_preset_aware
    assert_empty Dir.glob(File.join(@output, "**", "*"))

    content = @pipeline.resolve("/img/same.jpg?version=1", preset: :content)
    avatar = @pipeline.resolve("/img/same.jpg", preset: :avatar)

    assert(content[:variants].all? { |variant| variant[:path].include?("content-400w") })
    assert(avatar[:variants].all? { |variant| variant[:path].include?("avatar-96x96") })
  end

  def test_source_relative_identity_avoids_same_basename_collisions
    first = @pipeline.resolve("/img/same.jpg", preset: :content)
    second = @pipeline.resolve("/img/nested/same.webp", preset: :content)

    refute_equal first[:variants].first[:path], second[:variants].first[:path]
    assert_includes first[:variants].first[:path], "/img/same-jpg-"
    assert_includes second[:variants].first[:path], "/img/nested/same-webp-"
  end

  def test_unknown_external_and_traversal_sources_are_ignored
    assert_nil @pipeline.resolve("https://example.com/image.jpg")
    assert_nil @pipeline.resolve("/img/../secret.jpg")
    assert_nil @pipeline.resolve("/img/missing.jpg")
  end

  def test_cached_derivatives_are_materialized_after_output_is_cleaned
    entry = @pipeline.resolve("/img/same.jpg", preset: :content)
    cached_files = Dir.glob(File.join(@tmp, "cache", "files", "**", "*")).select { |path| File.file?(path) }
    cached_mtimes = cached_files.to_h { |path| [path, File.mtime(path)] }
    FileUtils.remove_entry(@output)

    fresh_pipeline = Bridgetown::ImagePipeline::Pipeline.new(
      config: @config,
      root_dir: @tmp,
      output_root: @output,
      cache_root: File.join(@tmp, "cache")
    ).refresh
    restored = fresh_pipeline.resolve("/img/same.jpg", preset: :content)

    assert_equal entry, restored
    assert_equal(cached_mtimes, cached_files.to_h { |path| [path, File.mtime(path)] })
    restored[:variants].each do |variant|
      assert File.exist?(File.join(@output, variant[:path]))
    end
  end
end

class HelperTest < Minitest::Test
  def setup
    config = Bridgetown::ImagePipeline::Config.from(
      formats: [:webp],
      presets: { avatar: { sizes: [[96, 96], [192, 192]], fit: :fill } },
      default_preset: :avatar
    )
    pipeline = FakePipeline.new([[["/images/known.jpg", :avatar], ImagePipelineTestData.entry]].to_h)
    @helpers = Bridgetown::ImagePipeline::Helpers.new(pipeline: pipeline, config: config)
  end

  def test_picture_tag_resolves_selected_preset_and_preserves_attributes
    html = @helpers.picture_tag(
      "/images/known.jpg",
      preset: :avatar,
      alt: "Person",
      sizes: "96px",
      width: 96,
      height: 96,
      class: "avatar"
    )

    assert_includes html, "<picture>"
    assert_includes html, 'type="image/webp"'
    assert_includes html, 'sizes="96px"'
    assert_includes html, 'width="96"'
    assert_includes html, 'height="96"'
    assert_includes html, 'class="avatar"'
  end

  def test_unknown_source_falls_back_to_original
    html = @helpers.picture_tag("/images/missing.svg", alt: "Icon")

    assert_includes html, '<img src="/images/missing.svg"'
    refute_includes html, "<picture>"
  end
end

class InspectorTest < Minitest::Test
  def setup
    @config = Bridgetown::ImagePipeline::Config.from(
      formats: [:webp],
      auto_rewrite: true,
      default_preset: :content,
      presets: {
        content: { widths: [400, 1200], fit: :limit, default_sizes: "90vw" },
        avatar: { sizes: [[96, 96]], fit: :fill }
      }
    )
    entries = {
      ["/images/known.jpg", :content] => ImagePipelineTestData.entry,
      ["/images/known.jpg", :avatar] => ImagePipelineTestData.entry
    }
    @inspector = Bridgetown::ImagePipeline::Inspector.new(
      pipeline: FakePipeline.new(entries),
      config: @config
    )
  end

  def test_rewrites_with_default_preset_and_preserves_attributes
    output = @inspector.rewrite(
      '<html><body><a href="/"><img src="/images/known.jpg" alt="x" title="y" class="photo"></a></body></html>'
    )

    assert_includes output, "<a href=\"/\"><picture>"
    assert_includes output, 'alt="x"'
    assert_includes output, 'title="y"'
    assert_includes output, 'class="photo"'
    assert_includes output, 'loading="lazy"'
    assert_includes output, 'decoding="async"'
    assert_includes output, 'sizes="90vw"'
  end

  def test_honors_and_removes_explicit_preset
    output = @inspector.rewrite(
      '<html><body><img src="/images/known.jpg" alt="x" data-image-preset="avatar"></body></html>'
    )

    assert_includes output, "<picture>"
    refute_includes output, "data-image-preset"
  end

  def test_skips_owned_or_ineligible_images
    html = <<~HTML
      <html><body>
        <picture><img src="/images/known.jpg"></picture>
        <img src="/images/known.jpg" srcset="/custom.jpg 1x">
        <img src="/images/known.jpg" data-no-pipeline>
        <img src="https://example.com/image.jpg">
      </body></html>
    HTML
    output = @inspector.rewrite(html)

    assert_equal 1, output.scan("<picture>").length
    assert_includes output, 'srcset="/custom.jpg 1x"'
    assert_includes output, "data-no-pipeline"
    assert_includes output, "https://example.com/image.jpg"
  end
end

class BgImageSetTest < Minitest::Test
  def test_emits_image_set_and_nearest_breakpoint_variant
    css = Bridgetown::ImagePipeline::BgImageSet.css(
      class_name: "bg-img-hero",
      variants: {
        400 => { webp: "/hero-400.webp" },
        1200 => { webp: "/hero-1200.webp" }
      },
      breakpoints: { 640 => 400 },
      default_width: 1200
    )

    assert_includes css, ".bg-img-hero{background-image:image-set(url(/hero-1200.webp) type('image/webp'))}"
    assert_includes css, "@media (max-width:640px)"
  end
end
