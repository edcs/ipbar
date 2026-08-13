# Template for a Homebrew cask. Publish this in your own tap first
# (github.com/edcs/homebrew-tap), which users install with:
#
#   brew tap edcs/tap
#   brew install --cask ipbar
#
# homebrew-cask proper has notability requirements (roughly 30+ stars/forks),
# so treat submitting upstream as a later milestone.
cask "ipbar" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_PRINTED_BY_MAKE_RELEASE"

  url "https://github.com/edcs/ipbar/releases/download/v#{version}/IPBar-#{version}.zip"
  name "IPBar"
  desc "Menu bar IP address display with named addresses and VPN state"
  homepage "https://github.com/edcs/ipbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "IPBar.app"

  zap trash: [
    "~/Library/Preferences/dev.ecs.IPBar.plist",
  ]
end
