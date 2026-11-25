# RenderDock, built from source by Homebrew.
#
#   brew tap jarnoniu/renderdock https://github.com/JarnoNiu/RenderDock
#   brew trust jarnoniu/renderdock      # only where Homebrew refuses formulae from a tap it was not told to trust
#   brew install renderdock
#
# There is no download of the app itself: it is not notarised. This builds it on your Mac instead, which needs
# nothing beyond the Command Line Tools.
#
# Run under Homebrew 7.0.11 on macOS (Apple silicon) on 2026-11-25, from a local tap holding this repository:
# refused until the tap was trusted, then fetched, built in Homebrew's sandbox, installed and linked; `brew test`
# and `brew audit --strict` passed; `brew uninstall` took everything away again. Not covered: the tap taken from
# GitHub (the formula has to be on the default branch first), `brew upgrade`, `--HEAD`, and opening the app from
# the prefix.
class Renderdock < Formula
  desc "Dock for render progress and coding agents' sessions"
  homepage "https://github.com/JarnoNiu/RenderDock"
  url "https://github.com/JarnoNiu/RenderDock/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "7f8be990356be62de2bac8bc8a5be5b495d7cbf01e8aeb217509aa5e7d37071b"
  license "MIT"
  head "https://github.com/JarnoNiu/RenderDock.git", branch: "main"

  depends_on macos: :sonoma

  def install
    # Homebrew builds in a sandbox of its own, and the Swift package manager cannot start a second one inside it.
    inreplace "scripts/build-app.sh", "swift build -c release", "swift build -c release --disable-sandbox"
    system "zsh", "scripts/build-app.sh"
    prefix.install "build/RenderDock.app"
    bin.install_symlink prefix/"RenderDock.app/Contents/Helpers/renderdock"
  end

  def caveats
    <<~EOS
      RenderDock is an app that lives in the menu bar. Start it with:
        open #{opt_prefix}/RenderDock.app

      "Launch at Login" only works for a copy in Applications. To put one there:
        ditto #{opt_prefix}/RenderDock.app /Applications/RenderDock.app && open /Applications/RenderDock.app

      The command line is `renderdock` (try `renderdock status`).
      Each build is signed ad hoc, so after an upgrade macOS may ask again for the permissions it had given.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/renderdock version")
    assert_path_exists prefix/"RenderDock.app/Contents/MacOS/RenderDock"
  end
end
