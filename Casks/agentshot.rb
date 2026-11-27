cask "agentshot" do
  version "0.1.0"
  sha256 "3dde28570729ab7ad67742ef5eec5248d6af62ce4eedec3ab66863511cc02cde"

  url "https://raw.githubusercontent.com/therealharpaljadeja/agentshot/main/dist/agentshot-#{version}-universal.tar.gz"
  name "agentshot"
  desc "Agent-first screenshot capture and annotation tooling"
  homepage "https://github.com/therealharpaljadeja/agentshot"

  depends_on macos: :sonoma

  binary "agentshot"
end
