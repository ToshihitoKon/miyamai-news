# frozen_string_literal: true

require "spec_helper"
require "internal/progress"

RSpec.describe Internal::Progress do
  after { described_class.ci = false }

  it "prints one plain line at start and one at the end in ci mode, without spinner animation" do
    described_class.ci = true
    allow(TTY::Spinner).to receive(:new)

    expect do
      progress = described_class.start("selecting news [agy]")
      progress.success("(done)")
    end.to output("[..] selecting news [agy]\n[ok] selecting news [agy] (done)\n").to_stderr

    expect(TTY::Spinner).not_to have_received(:new)
  end

  it "reports failures as a plain line in ci mode" do
    described_class.ci = true

    expect { described_class.start("formatting").error("(failed)") }
      .to output(a_string_ending_with("[ng] formatting (failed)\n")).to_stderr
  end

  it "uses an auto-spinning TTY::Spinner outside ci mode" do
    spinner = instance_double(TTY::Spinner, auto_spin: nil)
    allow(TTY::Spinner).to receive(:new).and_return(spinner)

    expect(described_class.start("selecting news")).to be(spinner)
    expect(spinner).to have_received(:auto_spin)
  end
end
