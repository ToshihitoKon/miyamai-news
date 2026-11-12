# frozen_string_literal: true

require "spec_helper"
require "json"
require "internal/restricted_agy"

RSpec.describe Internal::RestrictedAgy do
  let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:ng) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  before do
    allow(Config.ai_agent).to receive(:print_timeout).and_return("15m")
    allow(Config.ai_agent).to receive(:bin).and_return("agy")
  end

  describe ".configured?" do
    it "is true for agy on PATH or a path to an agy binary" do
      %w[agy /opt/homebrew/bin/agy].each do |bin|
        allow(Config.ai_agent).to receive(:bin).and_return(bin)
        expect(described_class.configured?).to be(true)
      end
    end

    it "is false for another AI CLI" do
      allow(Config.ai_agent).to receive(:bin).and_return("claude")
      expect(described_class.configured?).to be(false)
    end
  end

  it "runs the agy binary configured in ai_agent.bin" do
    allow(Config.ai_agent).to receive(:bin).and_return("/opt/homebrew/bin/agy")
    allow(Open3).to receive(:capture3).and_return(["out", "", ok])

    described_class.run("msg", "prompt", model: "m", workdir: "/w")

    expect(Open3).to have_received(:capture3) do |*argv, **|
      expect(argv.first).to eq("/opt/homebrew/bin/agy")
    end
  end

  it "passes only a read_file allow rule for readable_dir and runs inside workdir" do
    allow(Open3).to receive(:capture3).and_return(["out", "", ok])

    result = described_class.run("msg", "prompt", model: "m", workdir: "/w", readable_dir: "/w")

    expect(result).to eq("out")
    expect(Open3).to have_received(:capture3) do |*argv, **opts|
      expect(argv.first).to eq("agy")
      expect(argv).not_to include("--dangerously-skip-permissions")
      settings = JSON.parse(argv[argv.index("--settings") + 1])
      expect(settings).to eq("permissions" => { "allow" => ["read_file(/w/*)"] })
      expect(argv.each_cons(2).to_a).to include(
        ["--model", "m"], ["--print-timeout", "15m"], ["--add-dir", "/w"], ["-p", "prompt"]
      )
      expect(opts).to eq(chdir: "/w")
    end
  end

  it "allows no tool at all when readable_dir is nil" do
    allow(Open3).to receive(:capture3).and_return(["out", "", ok])

    described_class.run("msg", "prompt", model: "m", workdir: "/w")

    expect(Open3).to have_received(:capture3) do |*argv, **|
      expect(JSON.parse(argv[argv.index("--settings") + 1])).to eq("permissions" => { "allow" => [] })
    end
  end

  it "does not leave the prompt in the episode log" do
    allow(Open3).to receive(:capture3).and_return(["out", "", ok])
    allow(Internal::EpisodeLogger).to receive(:record)

    described_class.run("msg", "secret prompt", model: "m", workdir: "/w")

    expect(Internal::EpisodeLogger).to have_received(:record) do |step, **fields|
      expect(step).to eq("msg")
      expect(fields).to include(bin: "agy", model: "m", exit_code: 0, stdout: "out", stderr: "")
      expect(fields.values.join).not_to include("secret prompt")
    end
  end

  it "raises Error when agy exits non-zero" do
    allow(Open3).to receive(:capture3).and_return(["", "boom", ng])

    expect { described_class.run("msg", "p", model: "m", workdir: "/w") }.to raise_error(described_class::Error, /exit 1/)
  end

  it "raises Error on print timeout even if the exit status is success" do
    allow(Open3).to receive(:capture3).and_return(["partial", "[agy] ... returning partial output", ok])

    expect { described_class.run("msg", "p", model: "m", workdir: "/w") }.to raise_error(described_class::Error, /print timeout/)
  end

  it "raises Error on blank stdout even if the exit status is success, as when agy denies a tool" do
    allow(Open3).to receive(:capture3).and_return([" \n", "", ok])

    expect { described_class.run("msg", "p", model: "m", workdir: "/w") }
      .to raise_error(described_class::Error, /no output/)
  end

  it "names the signal when agy is killed" do
    killed = instance_double(Process::Status, success?: false, exitstatus: nil, termsig: 9)
    allow(Open3).to receive(:capture3).and_return(["", "", killed])

    expect { described_class.run("msg", "p", model: "m", workdir: "/w") }
      .to raise_error(described_class::Error, /killed by signal 9/)
  end

  it "detects the print timeout even when stderr holds invalid UTF-8 bytes" do
    stderr = "\xfe [agy] ... returning partial output".dup.force_encoding("UTF-8")
    allow(Open3).to receive(:capture3).and_return(["partial", stderr, ok])

    expect { described_class.run("msg", "p", model: "m", workdir: "/w") }
      .to raise_error(described_class::Error, /print timeout/)
  end

  it "returns stdout with invalid UTF-8 bytes unchanged for the caller to report" do
    broken = "1: \xff".dup.force_encoding("UTF-8")
    allow(Open3).to receive(:capture3).and_return([broken, "", ok])

    expect(described_class.run("msg", "p", model: "m", workdir: "/w")).to eq(broken)
  end

  it "refuses a readable dir that cannot be written in an allow rule, without starting agy" do
    allow(Open3).to receive(:capture3)

    expect { described_class.run("msg", "p", model: "m", workdir: "/w", readable_dir: "/My Projects/w (1)") }
      .to raise_error(described_class::Error, %r{allow rule.*/My Projects/w \(1\)})
    expect(Open3).not_to have_received(:capture3)
  end

  [Errno::ENOENT, Errno::EACCES].each do |error_class|
    it "raises Error instead of #{error_class} when agy cannot be started" do
      allow(Open3).to receive(:capture3).and_raise(error_class, "agy")

      expect { described_class.run("msg", "p", model: "m", workdir: "/w") }
        .to raise_error(described_class::Error, /cannot run agy/)
    end
  end
end
