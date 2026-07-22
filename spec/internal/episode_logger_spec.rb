# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "internal/episode_logger"

RSpec.describe Internal::EpisodeLogger do
  let(:work_dir) { Dir.mktmpdir }
  let(:log_path) { File.join(work_dir, "20260714_afternoon.log") }

  after { FileUtils.remove_entry(work_dir) }

  describe ".record" do
    context "before configure has been called" do
      it "does nothing (no-op) instead of raising" do
        expect { described_class.record("selector", model: "test-model") }.not_to raise_error
      end
    end

    context "after configure" do
      before { described_class.configure(log_path) }

      it "appends a header line with the given fields" do
        described_class.record("selector", model: "test-model", duration_sec: 1.5, exit_code: 0)

        expect(File.read(log_path)).to include("step=selector")
        expect(File.read(log_path)).to include("model=test-model")
        expect(File.read(log_path)).to include("duration_sec=1.5")
        expect(File.read(log_path)).to include("exit_code=0")
      end

      it "wraps stdout/stderr in distinct markers and omits blank sections" do
        described_class.record("selector", stdout: "hello", stderr: "")

        content = File.read(log_path)
        expect(content).to include("___STDOUT_START___\nhello\n___STDOUT_END___")
        expect(content).not_to include("___STDERR_START___")
      end

      it "appends across multiple calls without truncating the file" do
        described_class.record("selector", model: "m1")
        described_class.record("extractor", model: "m2")

        content = File.read(log_path)
        expect(content).to include("step=selector")
        expect(content).to include("step=extractor")
      end

      it "does not interleave lines when called concurrently from multiple threads" do
        threads = Array.new(8) do |i|
          Thread.new { described_class.record("worker", index: i, stdout: "line-#{i}\nline-#{i}\nline-#{i}") }
        end
        threads.each(&:join)

        lines = File.readlines(log_path)
        # 各エントリは "___STDOUT_START___" から "___STDOUT_END___" までの間、必ず
        # 同一スレッドの3行(line-i, line-i, line-i)だけが入っている（他スレッドの行が
        # 混ざっていない）ことを確認する。
        starts = lines.each_index.select { |i| lines[i].strip == "___STDOUT_START___" }
        expect(starts.size).to eq(8)
        starts.each do |start_index|
          body = lines[(start_index + 1)..(start_index + 3)].map(&:strip)
          expect(body.uniq.size).to eq(1)
        end
      end
    end
  end
end
