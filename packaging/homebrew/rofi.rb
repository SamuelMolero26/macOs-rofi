# Template rendered by .github/workflows/release.yml, which fills url and sha256 per release.
class Rofi < Formula
  desc "Native macOS port of the rofi launcher and dmenu replacement"
  homepage "https://github.com/SamuelMolero26/macOs-rofi"
  url "@URL@"
  sha256 "@SHA256@"
  license "MIT"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release"
    bin.install ".build/release/rofi"
  end

  test do
    assert_equal "b\n", pipe_output("#{bin}/rofi -dmenu -dump", "b\n")
  end
end
