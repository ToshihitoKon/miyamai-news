# frozen_string_literal: true

module Internal
  # GitHub Releases フィード固有の知識を隔離する。
  module GithubReleases
    RELEASE_LINK = %r{\Ahttps?://github\.com/[^/]+/(?<repo>[^/]+)/releases/tag/}

    class << self
      # link がリリースページなら、title の先頭にリポジトリ名を付けて返す。
      # リリースページでない、または title が既にリポジトリ名で始まっていれば title のまま。
      def title_with_repo(title, link)
        repo = link[RELEASE_LINK, :repo]
        return title unless repo
        return title if title.downcase.start_with?(repo.downcase)

        "#{repo} #{title}"
      end
    end
  end
end
