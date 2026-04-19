##
# Homebrew formula for the `lmd` LM Studio replacement.
#
# Install via a tap:
#   brew tap agoodkind/tap
#   brew install lmd
#
# This formula is template ready. Replace the `url` and `sha256` lines
# with a tagged release tarball hash before shipping to users. Until
# that first tag, run `brew install --HEAD lmd` which builds straight
# from `main`.
##
class Lmd < Formula
  desc "Single-binary LM Studio replacement for Apple Silicon (broker + TUI + bench + QA)"
  homepage "https://github.com/agoodkind/lmd"
  license "MIT"

  # Stable release. Replace with an annotated tag when cutting the
  # first public version.
  url "https://github.com/agoodkind/lmd/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  version "0.1.0"

  head "https://github.com/agoodkind/lmd.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release"

    build_dir = ".build/release"

    # Dispatcher plus every sibling binary it execs into.
    bin.install "#{build_dir}/lmd"
    bin.install "#{build_dir}/lmd-serve"
    bin.install "#{build_dir}/lmd-tui"
    bin.install "#{build_dir}/lmd-bench"
    bin.install "#{build_dir}/lmd-qa"

    # LaunchAgent template. Users copy it into
    # ~/Library/LaunchAgents/ and bootstrap manually. Homebrew does
    # not install into that path on its own.
    (share/"lmd").install "deploy/io.goodkind.lmd.serve.plist.example"
    (share/"lmd").install "plan" => "plan"
  end

  def caveats
    <<~EOS
      To run the broker as a LaunchAgent:
        sed "s|{{LMD_SERVE_PATH}}|#{opt_bin}/lmd-serve|g" \\
          #{opt_share}/lmd/io.goodkind.lmd.serve.plist.example \\
          > ~/Library/LaunchAgents/io.goodkind.lmd.serve.plist
        launchctl bootstrap gui/$(id -u) \\
          ~/Library/LaunchAgents/io.goodkind.lmd.serve.plist

      Tail unified logs:
        log stream --subsystem io.goodkind.lmd --info

      Foreground run:
        lmd serve                 # OpenAI broker + sampler + fan control on :5400
        lmd tui                   # multi-tab dashboard
        lmd bench run <cfg.toml>  # benchmark orchestrator
    EOS
  end

  test do
    # Minimum viable sanity: the binary starts, prints help, exits 0.
    assert_match "lmd", shell_output("#{bin}/lmd --help")
    assert_match "lmd", shell_output("#{bin}/lmd --version")
  end
end
