# Homebrew cask for Tokenamp, published through the personal tap lobabobloblaw/homebrew-tap
# (as Casks/tokenamp.rb), so users can run `brew install --cask lobabobloblaw/tap/tokenamp`.
#
# This file is the template. For each release, packaging/homebrew/update_cask.sh writes the
# version and the sha256 of the published zip into a copy for the tap (see packaging/README.md).
# The sha256 below is a placeholder and will not match any real download.
cask "tokenamp" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/lobabobloblaw/tokenamp/releases/download/v#{version}/Tokenamp-#{version}.zip"
  name "Tokenamp"
  desc "Claude plan usage shown as a Winamp 2.x player with classic skin support"
  homepage "https://github.com/lobabobloblaw/tokenamp"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Minimum macOS 13. Current Homebrew reads the bare symbol as ">=" and deprecates the older
  # string form `">= :ventura"`, which prints a warning on every install.
  depends_on macos: :ventura

  app "Tokenamp.app"

  zap trash: [
    "~/Library/Application Support/Tokenamp",
    "~/Library/Preferences/local.tokenamp.app.plist",
  ]

  # Remove this caveat once releases are signed with a Developer ID and notarized.
  caveats <<~EOS
    Tokenamp is not notarized by Apple yet, so macOS blocks its first launch after every
    install or upgrade. Either clear the quarantine flag:

      xattr -dr com.apple.quarantine #{appdir}/Tokenamp.app

    or open Tokenamp once, then go to System Settings > Privacy & Security and click
    "Open Anyway" next to the message about Tokenamp.
  EOS
end
