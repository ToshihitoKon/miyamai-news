# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "internal/node_deps"

RSpec.describe Internal::NodeDeps do
  describe ".validate_web_push!" do
    it "passes when node_modules/web-push is installed" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "node_modules", "web-push"))
        File.write(File.join(dir, "node_modules", "web-push", "package.json"), "{}")

        expect { described_class.validate_web_push!(root_dir: dir) }.not_to raise_error
      end
    end

    it "raises MissingDependencyError when node_modules/web-push is absent" do
      Dir.mktmpdir do |dir|
        expect { described_class.validate_web_push!(root_dir: dir) }
          .to raise_error(Internal::NodeDeps::MissingDependencyError, /npm install/)
      end
    end
  end
end
