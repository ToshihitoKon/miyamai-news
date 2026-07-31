# frozen_string_literal: true

module Internal
  # src/index.js は web_push.js を無条件に static import するため、
  # config.yaml の web_push セクションの有無に関わらず deploy には
  # node_modules/web-push が必須になる。
  module NodeDeps
    MissingDependencyError = Class.new(StandardError)

    def self.validate_web_push!(root_dir:)
      return if File.exist?(File.join(root_dir, "node_modules", "web-push", "package.json"))

      raise MissingDependencyError, "node_modules/web-push not found. Run `npm install` (see README.md)."
    end
  end
end
