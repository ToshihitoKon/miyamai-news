# frozen_string_literal: true

require "tmpdir"

module Internal
  module NodeDeps
    MissingDependencyError = Class.new(StandardError)

    # Site#deploy が呼ぶ `wrangler` と同じ解決経路（PATH 経由の bare 呼び出し）を
    # 使う。npx 経由にすると別バージョンの wrangler を検証してしまいかねない。
    def self.validate_wrangler_build!(root_dir:)
      Dir.mktmpdir("miyamai_wrangler_dryrun") do |empty_assets_dir|
        ok = Dir.chdir(root_dir) do
          system("wrangler", "deploy", "--dry-run", "--assets", empty_assets_dir, out: File::NULL)
        end
        return if ok

        raise MissingDependencyError, "pre-deploy build check failed (`wrangler deploy --dry-run`); see output above."
      end
    end
  end
end
