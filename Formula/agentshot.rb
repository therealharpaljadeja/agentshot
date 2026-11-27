class Agentshot < Formula
  desc "Agent-first macOS screenshot capture and annotation tooling"
  homepage "https://github.com/therealharpaljadeja/agentshot"
  url "https://raw.githubusercontent.com/therealharpaljadeja/agentshot/main/dist/agentshot-0.1.0-universal.tar.gz"
  version "0.1.0"
  sha256 "3dde28570729ab7ad67742ef5eec5248d6af62ce4eedec3ab66863511cc02cde"

  depends_on macos: :sonoma

  def install
    bin.install "agentshot"
  end

  test do
    output = shell_output("#{bin}/agentshot --help")
    assert_match "agentshot", output
    assert_match "capture fullscreen", output
  end
end
