# The template CI renders into edcs/homebrew-tap when a release is tagged.
#
# __VERSION__ and __SHA256__ are filled in by .github/workflows/release.yml from
# the tag and the zip it built, so this is never edited by hand and the cask
# cannot drift from the app it installs.
#
# homebrew-cask proper has notability requirements, roughly 30+ stars or forks,
# so submitting upstream is a later milestone.
cask "ipbar" do
  version "__VERSION__"
  sha256 "__SHA256__"

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
