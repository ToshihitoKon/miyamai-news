# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/ai_cli"

RSpec.describe Internal::AiCli do
  def fake_status(exitstatus)
    instance_double(Process::Status, success?: exitstatus.zero?, exitstatus: exitstatus)
  end

  describe ".run" do
    it "passes --print-timeout to a non-claude bin" do
      allow(Config.ai_agent).to receive_messages(bin: "agy", model: "gemini-3.8-flash-high", print_timeout: "15m")
      allow(described_class).to receive(:run_with_spinner).and_return("ok")

      described_class.run("doing thing", "prompt")

      expect(described_class).to have_received(:run_with_spinner).with(
        anything, anything, "agy", "--model", "gemini-3.8-flash-high", "--dangerously-skip-permissions",
        "--print-timeout", "15m", "--add-dir", Dir.pwd, "-p", "prompt",
        fatal: true, log_meta: { bin: "agy", model: "gemini-3.8-flash-high" }, cleanup_paths_on_timeout: []
      )
    end

    it "does not pass --print-timeout to claude" do
      allow(Config.ai_agent).to receive_messages(bin: "claude", model: "claude-opus-4-8", effort: nil)
      allow(described_class).to receive(:run_with_spinner).and_return("ok")

      described_class.run("doing thing", "prompt")

      expect(described_class).to have_received(:run_with_spinner) do |*args|
        expect(args).not_to include("--print-timeout")
      end
    end

    it "forwards cleanup_paths_on_timeout to run_with_spinner" do
      allow(Config.ai_agent).to receive_messages(bin: "agy", model: "gemini-3.8-flash-high", print_timeout: "15m")
      allow(described_class).to receive(:run_with_spinner).and_return("ok")

      described_class.run("doing thing", "prompt", cleanup_paths_on_timeout: ["/tmp/news_facts.txt"])

      expect(described_class).to have_received(:run_with_spinner).with(
        anything, anything, "agy", "--model", "gemini-3.8-flash-high", "--dangerously-skip-permissions",
        "--print-timeout", "15m", "--add-dir", Dir.pwd, "-p", "prompt",
        fatal: true, log_meta: { bin: "agy", model: "gemini-3.8-flash-high" },
        cleanup_paths_on_timeout: ["/tmp/news_facts.txt"]
      )
    end
  end

  describe ".run_with_spinner" do
    it "treats a print-timeout partial output as a failure even when exit code is 0" do
      allow(Open3).to receive(:capture3).and_return(
        ["partial stdout", "[agy] print timeout after 5m0s with turn in progress; returning partial output\n",
         fake_status(0)]
      )
      allow(Internal::EpisodeLogger).to receive(:record)

      expect do
        described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy")
      end.to raise_error(SystemExit)
    end

    it "returns nil instead of aborting when fatal: false and a print timeout occurs" do
      allow(Open3).to receive(:capture3).and_return(
        ["", "[agy] print timeout after 5m0s with turn in progress; returning partial output\n", fake_status(0)]
      )
      allow(Internal::EpisodeLogger).to receive(:record)

      result = described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy", fatal: false)

      expect(result).to be_nil
    end

    it "succeeds normally when exit code is 0 and stderr has no partial-output marker" do
      allow(Open3).to receive(:capture3).and_return(["done", "", fake_status(0)])
      allow(Internal::EpisodeLogger).to receive(:record)

      result = described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy")

      expect(result).to eq("done")
    end

    it "aborts on a genuine non-zero exit even without the marker" do
      allow(Open3).to receive(:capture3).and_return(["", "boom", fake_status(1)])
      allow(Internal::EpisodeLogger).to receive(:record)

      expect do
        described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy")
      end.to raise_error(SystemExit)
    end

    it "deletes cleanup_paths_on_timeout when a print timeout is detected, before aborting" do
      Dir.mktmpdir do |dir|
        partial_path = File.join(dir, "news_facts.txt")
        File.write(partial_path, "truncated by agy before it timed out")
        allow(Open3).to receive(:capture3).and_return(
          ["", "[agy] print timeout after 5m0s with turn in progress; returning partial output\n",
           fake_status(0)]
        )
        allow(Internal::EpisodeLogger).to receive(:record)

        expect do
          described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy",
            cleanup_paths_on_timeout: [partial_path])
        end.to raise_error(SystemExit)

        expect(File.exist?(partial_path)).to be false
      end
    end

    it "does not touch cleanup_paths_on_timeout on a genuine non-zero exit without the marker" do
      Dir.mktmpdir do |dir|
        existing_path = File.join(dir, "news_facts.txt")
        File.write(existing_path, "unrelated previously-reused content")
        allow(Open3).to receive(:capture3).and_return(["", "boom", fake_status(1)])
        allow(Internal::EpisodeLogger).to receive(:record)

        expect do
          described_class.send(:run_with_spinner, "msg", "AI CLI failed", "agy",
            cleanup_paths_on_timeout: [existing_path])
        end.to raise_error(SystemExit)

        expect(File.exist?(existing_path)).to be true
      end
    end
  end
end
