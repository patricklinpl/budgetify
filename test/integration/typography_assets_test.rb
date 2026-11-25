require "test_helper"
require "base64"
require "digest"

# Bundled Figtree: the token stack leads with it, the stylesheet declares both
# subsets with the license shipped beside them, and the embedded font bytes are
# exactly the reviewed upstream builds (compared by sha256 after decoding).
class TypographyAssetsTest < ActionDispatch::IntegrationTest
  LATIN_SHA256 = "4ba7d3d096695818fe0686be4f1e82c6b05134e18a22260336130335027462dd".freeze
  LATIN_EXT_SHA256 = "bf7828e2c258cffcfa50a048ee388a36b95bc16b452e8d36fa797635dbe15965".freeze

  def fonts_css = Rails.root.join("app/assets/stylesheets/00_fonts.css").read

  def faces = fonts_css.scan(/@font-face \{(.*?)\n\}/m).flatten

  def decoded(face) = Base64.strict_decode64(face[%r{url\("data:font/woff2;base64,([A-Za-z0-9+/=]+)"\)}, 1])

  test "the base font token leads with Figtree and keeps the system fallbacks" do
    tokens = Rails.root.join("app/assets/stylesheets/00_tokens.css").read
    stack = tokens[/--font-family-base:\s*([^;]+);/, 1]
    assert_match(/\AFigtree, "Helvetica Neue", Helvetica,/, stack)
    assert_includes stack, "system-ui"
    assert_match(/sans-serif\z/, stack)
  end

  test "both subsets are declared as variable weights with the license shipped beside them" do
    assert_equal 2, faces.size
    faces.each do |face|
      assert_includes face, 'font-family: "Figtree"'
      assert_includes face, "font-weight: 300 900"
      assert_includes face, "font-display: swap"
      assert_includes face, "unicode-range:"
    end
    license = Rails.root.join("app/assets/fonts/figtree/OFL.txt").read
    assert_includes license, "SIL OPEN FONT LICENSE Version 1.1"
    assert_includes license, "Figtree Project Authors"
  end

  test "the embedded font bytes are the unmodified upstream woff2 files" do
    latin, ext = faces.partition { |face| face.include?("U+0000-00FF") }.then { |a, b| [ a.first, b.first ] }
    assert_equal LATIN_SHA256, Digest::SHA256.hexdigest(decoded(latin))
    assert_equal LATIN_EXT_SHA256, Digest::SHA256.hexdigest(decoded(ext))
    [ latin, ext ].each { |face| assert_equal "wOF2", decoded(face).byteslice(0, 4) }
    assert_equal 20_156, decoded(latin).bytesize
    assert_equal 10_280, decoded(ext).bytesize
  end

  test "the stylesheet is served as CSS with both embedded faces" do
    get "/users/sign_in"
    href = css_select("link[rel=stylesheet]").map { |l| l["href"] }.find { |h| h.include?("/assets/00_fonts") }
    assert href
    get href
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_equal 2, response.body.scan("data:font/woff2;base64,").size
    assert_no_match(%r{url\("/figtree/}, response.body)
  end
end
