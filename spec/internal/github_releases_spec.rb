# frozen_string_literal: true

require "spec_helper"
require "internal/github_releases"

RSpec.describe Internal::GithubReleases do
  describe ".title_with_repo" do
    it "prefixes the repository name to a version-only release title" do
      link = "https://github.com/anthropics/claude-code/releases/tag/v2.1.318"

      expect(described_class.title_with_repo("v2.1.318", link)).to eq("claude-code v2.1.318")
    end

    it "uses the repository name even when the tag differs from the title" do
      link = "https://github.com/openai/codex/releases/tag/rust-v0.162.0-alpha.8"

      expect(described_class.title_with_repo("0.162.0-alpha.8", link)).to eq("codex 0.162.0-alpha.8")
    end

    it "does not prefix twice when the title already starts with the repository name" do
      link = "https://github.com/google-antigravity/antigravity-cli/releases/tag/1.5.0"

      expect(described_class.title_with_repo("Antigravity-CLI 1.5.0", link)).to eq("Antigravity-CLI 1.5.0")
    end

    it "keeps the title of a GitHub link that is not a release page" do
      link = "https://github.com/rcalixte/ncdu"

      expect(described_class.title_with_repo("ncdu: NCurses Disk Usage", link)).to eq("ncdu: NCurses Disk Usage")
    end

    it "keeps the title of a non-GitHub link" do
      link = "https://example.com/releases/tag/1.0.0"

      expect(described_class.title_with_repo("1.0.0", link)).to eq("1.0.0")
    end
  end
end
