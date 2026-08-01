# frozen_string_literal: true

require "tmpdir"

module Internal
  module NodeDeps
    MissingDependencyError = Class.new(StandardError)

    def self.validate_wrangler_build!(root_dir:)
      Dir.mktmpdir("miyamai_wrangler_dryrun") do |empty_assets_dir|
        ok = Dir.chdir(root_dir) do
          system("wrangler", "deploy", "--dry-run", "--assets", empty_assets_dir, out: File::NULL)
        end
        next if ok

        raise MissingDependencyError, "pre-deploy build check failed (`wrangler deploy --dry-run`); see output above."
      end
    end
  end
end
