# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/node_deps"

RSpec.describe Internal::NodeDeps do
  describe ".validate_wrangler_build!" do
    it "passes when the wrangler dry-run build succeeds" do
      allow(Internal::NodeDeps).to receive(:system).and_return(true)

      Dir.mktmpdir do |root_dir|
        expect { described_class.validate_wrangler_build!(root_dir: root_dir) }.not_to raise_error
      end
    end

    it "raises MissingDependencyError when the wrangler dry-run build fails" do
      allow(Internal::NodeDeps).to receive(:system).and_return(false)

      Dir.mktmpdir do |root_dir|
        expect { described_class.validate_wrangler_build!(root_dir: root_dir) }
          .to raise_error(Internal::NodeDeps::MissingDependencyError, /wrangler deploy --dry-run/)
      end
    end

    it "runs the dry-run in root_dir against a scratch assets directory" do
      Dir.mktmpdir do |root_dir|
        allow(Internal::NodeDeps).to receive(:system) do |*args, **_kwargs|
          expect(Dir.pwd).to eq(File.realpath(root_dir))
          expect(args[0..2]).to eq(["wrangler", "deploy", "--dry-run"])
          expect(args[3]).to eq("--assets")
          expect(Dir.exist?(args[4])).to be true
          true
        end

        described_class.validate_wrangler_build!(root_dir: root_dir)
      end
    end
  end
end
